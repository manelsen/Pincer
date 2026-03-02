defmodule Pincer.Connectors.Telegram.Commands do
  @moduledoc """
  Handlers for Telegram commands and callbacks using Telegex.
  """

  alias Pincer.Models
  alias Pincer.Config

  @doc """
  Handler for the /status command.
  Returns information about the bot's current state.
  """
  def handle_status do
    llm_config = Config.get(:llm, %{})
    provider = Map.get(llm_config, "provider", "not configured")
    model = deep_get(llm_config, [provider, "default_model"]) || "not configured"

    """
    ⚙️ **Pincer Status**

    🧠 **Model:** `#{model}`
    🌐 **Provider:** `#{provider}`
    📦 **Runtime:** Elixir/OTP (BEAM)
    """
  end

  @doc """
  Generates provider buttons for the /models command.
  """
  def provider_buttons do
    Models.providers()
    |> Enum.map(fn provider ->
      display_name =
        provider
        |> String.replace("_", " ")
        |> String.capitalize()

      button = %Telegex.Type.InlineKeyboardButton{
        text: display_name,
        callback_data: "prov:#{provider}"
      }

      if provider == "openrouter" do
        [
          button,
          %Telegex.Type.InlineKeyboardButton{
            text: "🆓 Free (OpenRouter)",
            callback_data: "free:openrouter"
          }
        ]
      else
        [button]
      end
    end)
  end

  @doc """
  Generates model selection buttons for a specific provider.
  """
  def model_buttons(provider) do
    models = Models.for_provider(provider)

    buttons =
      Enum.map(models, fn {label, id} ->
        [
          %Telegex.Type.InlineKeyboardButton{
            text: label,
            callback_data: "set:#{provider}:#{id}"
          }
        ]
      end)

    # Adds special buttons per provider
    buttons = add_special_buttons(buttons, provider)

    # Adds back button
    buttons ++
      [
        [
          %Telegex.Type.InlineKeyboardButton{
            text: "⬅️ Back",
            callback_data: "back:prov"
          }
        ]
      ]
  end

  defp add_special_buttons(buttons, "opencode_zen") do
    [
      [
        %Telegex.Type.InlineKeyboardButton{
          text: "🆓 Free (Search API)",
          callback_data: "free:opencode_zen"
        }
      ]
    ] ++ buttons
  end

  defp add_special_buttons(buttons, _), do: buttons

  @doc """
  Processes model selection and returns success/error message.
  """
  def set_model(provider, model_id) do
    case Config.set_model(model_id, provider) do
      {:ok, mid, p} -> {:ok, "✅ Active: #{p} / #{mid}"}
      {:error, reason} -> {:error, "❌ Error: #{inspect(reason)}"}
    end
  end

  @doc """
  Helper to edit message with text and markup in Telegex.
  """
  def edit_message_with_markup(chat_id, message_id, text, buttons) do
    markup = %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons}

    Telegex.edit_message_text(text,
      chat_id: chat_id,
      message_id: message_id,
      reply_markup: markup
    )
  end

  defp deep_get(map, keys) do
    Enum.reduce(keys, map, fn key, acc ->
      case acc do
        %{} -> Map.get(acc, key)
        _ -> nil
      end
    end)
  end
end
