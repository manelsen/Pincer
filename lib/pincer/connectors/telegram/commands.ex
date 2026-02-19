defmodule Pincer.Connectors.Telegram.Commands do
  @moduledoc """
  Handlers para comandos e callbacks do Telegram usando Telegex.
  """

  alias Pincer.Models
  alias Pincer.Config

  @doc """
  Handler para o comando /status.
  Retorna informações sobre o estado atual do bot.
  """
  def handle_status do
    llm_config = Config.get(:llm, %{})
    provider = Map.get(llm_config, "provider", "não configurado")
    model = deep_get(llm_config, [provider, "default_model"]) || "não configurado"

    """
    ⚙️ **Pincer Status**

    🧠 **Model:** `#{model}`
    🌐 **Provider:** `#{provider}`
    📦 **Runtime:** Elixir/OTP (BEAM)
    """
  end

  @doc """
  Gera botões de provedor para o comando /models.
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
  Gera os botões de seleção de modelo para um provedor específico.
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

    # Adiciona botões especiais por provedor
    buttons = add_special_buttons(buttons, provider)

    # Adiciona botão de voltar
    buttons ++
      [
        [
          %Telegex.Type.InlineKeyboardButton{
            text: "⬅️ Voltar",
            callback_data: "back:prov"
          }
        ]
      ]
  end

  defp add_special_buttons(buttons, "opencode_zen") do
    [
      [
        %Telegex.Type.InlineKeyboardButton{
          text: "🆓 Free (Buscar na API)",
          callback_data: "free:opencode_zen"
        }
      ]
    ] ++ buttons
  end

  defp add_special_buttons(buttons, _), do: buttons

  @doc """
  Processa a seleção de modelo e retorna mensagem de sucesso/erro.
  """
  def set_model(provider, model_id) do
    case Config.set_model(model_id, provider) do
      {:ok, mid, p} -> {:ok, "✅ Ativo: #{p} / #{mid}"}
      {:error, reason} -> {:error, "❌ Erro: #{inspect(reason)}"}
    end
  end

  @doc """
  Helper para editar mensagem com texto e markup no Telegex.
  """
  def edit_message_with_markup(chat_id, message_id, text, buttons) do
    markup = %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons}
    Telegex.edit_message_text(text, chat_id: chat_id, message_id: message_id, reply_markup: markup)
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
