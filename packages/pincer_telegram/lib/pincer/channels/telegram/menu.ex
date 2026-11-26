defmodule Pincer.Channels.Telegram.Menu do
  @moduledoc """
  Telegram interactive keyboards, reply markup, and callback query handling.
  """

  require Logger

  alias Pincer.Channels.Telegram.Session
  alias Pincer.Channels.Telegram.Transport

  @doc """
  Returns Telegram reply markup for menu affordance.

  Default mode is native-first (`remove_keyboard: true`) to avoid duplicated
  menu buttons on Telegram mobile. Set `channels.telegram.menu_keyboard: "persistent"`
  in config to force the legacy persistent keyboard.
  """
  @spec menu_reply_markup() :: map()
  def menu_reply_markup do
    case menu_keyboard_mode(Application.get_env(:pincer, :telegram_channel_config, %{})) do
      :persistent ->
        %{
          keyboard: [[%{text: PincerPorts.UX.menu_button_label()}]],
          resize_keyboard: true,
          one_time_keyboard: false,
          is_persistent: true
        }

      :native ->
        %{remove_keyboard: true}
    end
  end

  @doc """
  Sends the interactive help/menu message to a Telegram chat.
  """
  @spec send_menu(String.t() | integer()) :: {:ok, any()} | {:error, any()}
  def send_menu(chat_id) do
    Transport.send_message(chat_id, PincerPorts.UX.help_text(:telegram),
      reply_markup: menu_reply_markup()
    )
  end

  @doc """
  Builds inline keyboard rows for provider selection, preserving provider order
  and skipping providers whose callback payloads exceed Telegram's byte limit.
  """
  @spec build_provider_buttons([map()]) :: [[map()]]
  def build_provider_buttons(providers) do
    providers
    |> Enum.reduce([], fn provider, acc ->
      case PincerPorts.ChannelPolicy.provider_selector_id(:telegram, provider.id) do
        {:ok, callback_data} ->
          [[%{text: provider.name, callback_data: callback_data}] | acc]

        {:error, :payload_too_large} ->
          Logger.warning(
            "[TELEGRAM] Skipping provider button with oversized callback payload: #{inspect(provider.id)}"
          )

          acc

        {:error, _reason} ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Returns phase-specific reply markup for interactive project wizard prompts.
  """
  @spec project_reply_markup(String.t()) :: map() | nil
  def project_reply_markup(session_id) do
    case PincerPorts.Project.phase(session_id) do
      :await_kind ->
        %{
          keyboard: [[%{text: "software"}, %{text: "nao-software"}]],
          resize_keyboard: true,
          one_time_keyboard: true
        }

      _ ->
        nil
    end
  end

  @doc """
  Sends a fallback notice when an interactive menu cannot be built.
  """
  @spec interaction_unavailable(String.t() | integer()) :: {:ok, any()} | {:error, any()}
  def interaction_unavailable(chat_id) do
    Transport.send_message(
      chat_id,
      "Nao consegui montar o menu interativo agora. Use /menu para continuar.",
      reply_markup: menu_reply_markup()
    )
  end

  @doc """
  Processes an incoming Telegram callback query payload.
  """
  @spec handle_callback(String.t() | integer(), String.t() | nil, String.t(), integer()) :: any()
  def handle_callback(chat_id, chat_type, payload, message_id) do
    context = Session.context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    Session.ensure_core_started(context)

    case PincerPorts.ChannelPolicy.parse(:telegram, payload) do
      {:ok, {:page, provider_id, page}} ->
        render_models_page(
          chat_id,
          message_id,
          session_id,
          provider_id,
          page,
          "🤖 <b>Models from #{provider_id} (page #{page}):</b>"
        )

      {:ok, {:select_provider, provider_id}} ->
        render_models_page(
          chat_id,
          message_id,
          session_id,
          provider_id,
          1,
          "🤖 <b>Selecione o Modelo para #{provider_id}:</b>"
        )

      {:ok, {:select_model, provider_id, model}} ->
        PincerPorts.Session.set_model(session_id, provider_id, model)

        edit_callback_message(
          chat_id,
          message_id,
          "✅ <b>Model configured!</b>\nSession: <code>#{session_id}</code>\nProvider: <code>#{provider_id}</code>\nModel: <code>#{model}</code>",
          parse_mode: "HTML"
        )

      {:ok, :back_to_providers} ->
        render_providers_menu(chat_id, message_id)

      {:ok, :show_menu} ->
        send_menu(chat_id)

      {:ok, {:approval, decision}} ->
        handle_approval(chat_id, message_id, session_id, decision)

      {:error, reason} ->
        Logger.warning("[TELEGRAM] Invalid callback payload: #{inspect(reason)}")
        callback_invalid(chat_id)
    end
  end

  defp render_models_page(chat_id, message_id, session_id, provider_id, page, title) do
    models = PincerPorts.LLM.list_models(provider_id)
    current_model = current_model_for_session(session_id)
    buttons = PincerPorts.UX.build_keyboard(:telegram, provider_id, models, page, current_model)

    if buttons == [] do
      interaction_unavailable(chat_id)
    else
      edit_callback_message(
        chat_id,
        message_id,
        title,
        reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons},
        parse_mode: "HTML"
      )
    end
  end

  defp render_providers_menu(chat_id, message_id) do
    buttons = PincerPorts.LLM.list_providers() |> build_provider_buttons()

    if buttons == [] do
      interaction_unavailable(chat_id)
    else
      edit_callback_message(
        chat_id,
        message_id,
        "🔧 <b>Selecione o Provider:</b>",
        reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons},
        parse_mode: "HTML"
      )
    end
  end

  defp handle_approval(chat_id, message_id, session_id, :approved) do
    PincerPorts.Session.process_input(session_id, "aprovo")
    edit_callback_message(chat_id, message_id, "✅ Aprovado", parse_mode: "HTML")
  end

  defp handle_approval(chat_id, message_id, session_id, :rejected) do
    PincerPorts.Session.process_input(session_id, "rejeito")
    edit_callback_message(chat_id, message_id, "❌ Rejeitado", parse_mode: "HTML")
  end

  defp handle_approval(chat_id, message_id, session_id, :approve_all) do
    PincerPorts.Session.approve_all(session_id, 600)

    edit_callback_message(chat_id, message_id, "🔓 Auto-aprovação ativa por 10 minutos",
      parse_mode: "HTML"
    )
  end

  defp edit_callback_message(chat_id, message_id, text, opts) do
    case Transport.api_client().edit_message_text(chat_id, message_id, text, opts) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        Logger.warning("[TELEGRAM] Callback message edit failed: #{inspect(reason)}")

        Transport.send_message(
          chat_id,
          "Nao consegui atualizar o menu agora. Use /menu para continuar.",
          reply_markup: menu_reply_markup()
        )

        error
    end
  end

  defp callback_invalid(chat_id) do
    Transport.send_message(
      chat_id,
      "Opcao de menu desconhecida ou expirada. Use /menu para abrir novamente.",
      reply_markup: menu_reply_markup()
    )
  end

  defp menu_keyboard_mode(config) when is_map(config) do
    mode =
      config["menu_keyboard"] ||
        config[:menu_keyboard] ||
        config["menuKeyboard"] ||
        config[:menuKeyboard]

    case mode do
      mode when mode in ["persistent", :persistent, "custom", :custom] -> :persistent
      _ -> :native
    end
  end

  defp menu_keyboard_mode(_), do: :native

  defp current_model_for_session(session_id) do
    case PincerPorts.Session.get_status(session_id) do
      {:ok, %{model_override: %{model: model}}} -> model
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
