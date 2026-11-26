defmodule Pincer.Channels.Telegram.Commands do
  @moduledoc """
  Telegram bot command registration and slash-command execution.
  """

  require Logger

  alias Pincer.Channels.Shared.{Pairing, ProjectBridge}
  alias Pincer.Channels.Telegram.{Menu, Session, Transport}

  @doc """
  Registers Telegram bot commands using `PincerPorts.UX.registerable_commands/2`.
  """
  @spec register_commands() :: :ok
  def register_commands do
    policy = PincerPorts.UX.registerable_commands(:telegram, PincerPorts.UX.commands())

    Enum.each(policy.issues, fn issue ->
      Logger.warning("[TELEGRAM] Command policy issue: #{issue}")
    end)

    case Transport.api_client().set_my_commands(policy.commands, []) do
      {:ok, true} ->
        Logger.info("[TELEGRAM] Commands registered successfully.")

      {:error, reason} ->
        Logger.warning("[TELEGRAM] Failed to register commands: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Dispatches a parsed Telegram slash command.
  """
  @spec handle(String.t() | integer(), String.t(), String.t(), String.t() | nil) :: any()
  def handle(chat_id, "/ping", _text, _chat_type) do
    Transport.send_message(chat_id, "Pong! 🏓")
  end

  def handle(chat_id, cmd, _text, _chat_type) when cmd in ["/menu", "/help", "/commands"] do
    Menu.send_menu(chat_id)
  end

  def handle(chat_id, "/models", _text, _chat_type) do
    buttons = PincerPorts.LLM.list_providers() |> Menu.build_provider_buttons()

    if buttons == [] do
      Menu.interaction_unavailable(chat_id)
    else
      Transport.send_message(chat_id, "🔧 <b>Selecione o Provider:</b>",
        reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons}
      )
    end
  end

  def handle(chat_id, "/kanban", _text, chat_type) do
    session_id = Session.context_for_chat(chat_id, chat_type).session_id
    Transport.send_message(chat_id, PincerPorts.Project.kanban(session_id))
  end

  def handle(chat_id, "/project", text, chat_type) do
    context = Session.context_for_chat(chat_id, chat_type)
    response = PincerPorts.Project.project(context.session_id, text)
    send_project_message(chat_id, context.session_id, response)
    maybe_start_project_execution(chat_id, context)
  end

  def handle(chat_id, "/pair", text, chat_type) do
    old_session_id = Session.context_for_chat(chat_id, "private").session_id

    response =
      case Pairing.approve(:telegram, chat_id, text,
             is_dm: normalize_chat_type(chat_type) == "private",
             include_bound_agent: true,
             format_bound_agent: &"Esta DM agora aponta para o agente <code>#{&1}</code>.",
             on_approved: fn -> PincerPorts.Session.stop_session(old_session_id) end
           ) do
        {:ok, message} -> message
        {:error, _reason, message} -> message
      end

    Transport.send_message(chat_id, response)
  end

  def handle(chat_id, "/status", _text, chat_type) do
    context = Session.context_for_chat(chat_id, chat_type)
    Session.ensure_core_started(context)

    case PincerPorts.Project.handle_command(:status, nil, context.session_id) do
      {:ok, msg} -> Transport.send_message(chat_id, msg)
      {:error, reason} -> Transport.send_message(chat_id, "❌ #{reason}")
    end
  end

  def handle(chat_id, cmd, _text, chat_type) when cmd in ["/new", "/reset"] do
    context = Session.context_for_chat(chat_id, chat_type)
    Session.ensure_core_started(context)

    case PincerPorts.Session.reset(context.session_id) do
      :ok -> Transport.send_message(chat_id, "🔄 Session reset.")
      _ -> Transport.send_message(chat_id, "❌ Could not reset the session.")
    end
  end

  def handle(chat_id, "/model", text, chat_type) do
    context = Session.context_for_chat(chat_id, chat_type)
    Session.ensure_core_started(context)

    case String.split(String.trim(text), "/", parts: 2) do
      [provider, model] when provider != "" and model != "" ->
        PincerPorts.Session.set_model(context.session_id, provider, model)
        Transport.send_message(chat_id, "✅ Modelo: <code>#{provider}/#{model}</code>")

      _ ->
        Transport.send_message(
          chat_id,
          "Uso: /model <provider/modelo>\nEx: /model openrouter/mistral-7b"
        )
    end
  end

  def handle(chat_id, "/think", text, chat_type) do
    context = Session.context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    Session.ensure_core_started(context)

    level = text |> String.trim() |> String.downcase()

    new_level =
      if level in ["off", "low", "medium", "high"] do
        level
      else
        {:ok, status} = PincerPorts.Session.get_status(session_id)
        cycle_thinking(status[:thinking_level] || "off")
      end

    PincerPorts.Session.set_thinking(session_id, new_level)
    Transport.send_message(chat_id, "🧠 Thinking: <code>#{new_level}</code>")
  end

  def handle(chat_id, "/reasoning", text, chat_type) do
    context = Session.context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    Session.ensure_core_started(context)

    new_visible =
      case String.trim(text) |> String.downcase() do
        "on" ->
          true

        "off" ->
          false

        _ ->
          {:ok, status} = PincerPorts.Session.get_status(session_id)
          not (status[:reasoning_visible] || false)
      end

    PincerPorts.Session.set_reasoning_visible(session_id, new_visible)
    msg = if new_visible, do: "👁 Reasoning: visible", else: "🙈 Reasoning: oculto"
    Transport.send_message(chat_id, msg)
  end

  def handle(chat_id, "/verbose", text, chat_type) do
    context = Session.context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    Session.ensure_core_started(context)

    case String.trim(text) |> String.downcase() do
      "on" ->
        PincerPorts.Session.set_verbose(session_id, true)
        Transport.send_message(chat_id, "🔊 Verbose: on")

      "off" ->
        PincerPorts.Session.set_verbose(session_id, false)
        Transport.send_message(chat_id, "🔇 Verbose: off")

      _ ->
        Transport.send_message(chat_id, "Uso: /verbose on|off")
    end
  end

  def handle(chat_id, "/usage", text, chat_type) do
    context = Session.context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    Session.ensure_core_started(context)

    display = text |> String.trim() |> String.downcase()

    if display in ["off", "tokens", "full"] do
      PincerPorts.Session.set_usage(session_id, display)
      Transport.send_message(chat_id, "📊 Usage display: <code>#{display}</code>")
    else
      Transport.send_message(chat_id, "Uso: /usage off|tokens|full")
    end
  end

  def handle(chat_id, cmd, _text, _chat_type) do
    Transport.send_message(
      chat_id,
      "❓ Unknown command: <code>#{cmd}</code>\n#{PincerPorts.UX.unknown_command_hint()}",
      reply_markup: Menu.menu_reply_markup()
    )
  end

  @doc """
  Sends a project wizard response with any phase-specific reply keyboard.
  """
  @spec send_project_message(String.t() | integer(), String.t(), String.t()) :: any()
  def send_project_message(chat_id, session_id, response) do
    case Menu.project_reply_markup(session_id) do
      nil -> Transport.send_message(chat_id, response)
      reply_markup -> Transport.send_message(chat_id, response, reply_markup: reply_markup)
    end
  end

  @doc """
  Kicks off project execution if the project wizard reached a ready phase.
  """
  @spec maybe_start_project_execution(String.t() | integer(), PincerPorts.Session.Context.t()) ::
          :ok
  def maybe_start_project_execution(chat_id, %PincerPorts.Session.Context{} = context) do
    ProjectBridge.kickoff(context.session_id,
      ensure_session: fn -> Session.ensure_core_started(context) end,
      ensure_worker: fn -> Session.ensure_started(chat_id, context.session_id) end,
      send_message: fn text -> Transport.send_message(chat_id, text) end,
      log_tag: "TELEGRAM"
    )
  end

  defp normalize_chat_type(nil), do: ""

  defp normalize_chat_type(chat_type),
    do: chat_type |> to_string() |> String.trim() |> String.downcase()

  defp cycle_thinking("off"), do: "low"
  defp cycle_thinking("low"), do: "medium"
  defp cycle_thinking("medium"), do: "high"
  defp cycle_thinking(_), do: "off"
end
