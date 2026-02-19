defmodule Pincer.Channels.Telegram.Session do
  @moduledoc """
  Driven Adapter para Telegram.
  Um processo por chat ativo que escuta o PubSub e envia para a API do Telegram.
  """
  use GenServer
  require Logger

  def start_link(chat_id) do
    GenServer.start_link(__MODULE__, chat_id, name: via_tuple(chat_id))
  end

  defp via_tuple(chat_id), do: {:via, Registry, {Pincer.PubSub.Registry, "telegram_session_worker_#{chat_id}"}}

  def ensure_started(chat_id) do
    case Registry.lookup(Pincer.PubSub.Registry, "telegram_session_worker_#{chat_id}") do
      [] -> 
        # Inicia dinamicamente sob o Supervisor de Canais (ou um DynamicSupervisor próprio)
        # Para MVP, vamos iniciar linkado temporariamente ou usar um DynamicSupervisor se tivermos.
        # Vamos usar um DynamicSupervisor simples.
        Pincer.Channels.Telegram.SessionSupervisor.start_session(chat_id)
      _ -> :ok
    end
  end

  @impl true
  def init(chat_id) do
    # Se inscreve no tópico da sessão no Core
    Pincer.PubSub.subscribe("session:telegram_#{chat_id}")
    {:ok, chat_id}
  end

  @impl true
  def handle_info({:agent_response, text}, chat_id) do
    Telegex.send_message(chat_id, text)
    {:noreply, chat_id}
  end

  @impl true
  def handle_info({:agent_status, _text}, chat_id) do
    # Opcional: Enviar status como "Typing..." ou mensagem temporária
    Telegex.send_chat_action(chat_id, "typing")
    {:noreply, chat_id}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
