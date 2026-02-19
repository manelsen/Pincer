defmodule Pincer.Channels.Telegram do
  @moduledoc """
  Canal Telegram.
  Atua como um Supervisor para o Poller.
  """
  use Supervisor
  @behaviour Pincer.Channel
  require Logger

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  def init(config) do
    token_var = Map.get(config, "token_env", "TELEGRAM_BOT_TOKEN")
    token = System.get_env(token_var)

    if token && token != "" do
      Logger.info("Iniciando Canal Telegram (Token OK)...")
      Application.put_env(:telegex, :token, token)
      
      children = [
        Pincer.Channels.Telegram.UpdatesProvider
      ]
      
      Supervisor.init(children, strategy: :one_for_one)
    else
      Logger.warning("Token Telegram não encontrado. Canal ignorado.")
      :ignore
    end
  end

  def send_message(chat_id, text) do
    case Telegex.send_message(chat_id, text) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Pincer.Channels.Telegram.UpdatesProvider do
  use GenServer
  require Logger
  alias Pincer.Session.Server

  # Intervalo de polling (1s)
  @poll_interval 1000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{offset: 0}, name: __MODULE__)
  end

  def init(state) do
    Logger.info("Telegram Poller Iniciado (Manual Mode).")
    # Limpa webhook
    Telegex.delete_webhook()
    # Agenda primeiro poll
    schedule_poll()
    {:ok, state}
  end

  def handle_info(:poll, state) do
    new_offset = fetch_updates(state.offset)
    schedule_poll()
    {:noreply, %{state | offset: new_offset}}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp fetch_updates(offset) do
    # Chama get_updates com timeout longo para long polling
    case Telegex.get_updates(offset: offset, timeout: 10) do
      {:ok, updates} ->
        # Processa updates
        Enum.each(updates, &process_update/1)
        
        # Calcula novo offset (maior update_id + 1)
        if Enum.empty?(updates) do
          offset
        else
          List.last(updates).update_id + 1
        end

      {:error, reason} ->
        Logger.error("Erro no Polling Telegram: #{inspect(reason)}")
        offset
    end
  end

  defp process_update(%{message: %{text: text, chat: %{id: chat_id}}} = _update) when not is_nil(text) do
    session_id = "telegram_#{chat_id}"
    
    # Envia para o Session Server
    case Server.process_input(session_id, text) do
      {:ok, :started} -> :ok
      {:ok, :butler_notified} -> :ok
      {:ok, :queued} -> :ok
      {:ok, response} -> Telegex.send_message(chat_id, response)
      _ -> :ok
    end
  end

  defp process_update(_), do: :ok
end
