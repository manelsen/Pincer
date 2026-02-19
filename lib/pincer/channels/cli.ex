defmodule Pincer.Channels.CLI do
  @moduledoc """
  Canal CLI Backend.
  Implementa Pincer.Channel.
  Gerencia a sessão do terminal e encaminha mensagens para o processo frontend conectado.
  """
  use GenServer
  @behaviour Pincer.Channel
  require Logger

  def start_link(_config) do
    GenServer.start_link(__MODULE__, %{frontend_pid: nil}, name: __MODULE__)
  end

  # API para o Frontend se conectar
  def attach do
    GenServer.call(__MODULE__, :attach)
  end

  def init(state) do
    Logger.info("Canal CLI Habilitado.")
    # Se inscreve no tópico da sessão CLI
    Pincer.PubSub.subscribe("session:cli_user")
    {:ok, state}
  end

  def handle_call(:attach, {from_pid, _tag}, state) do
    # Garante que a sessão existe no nó servidor
    case Registry.lookup(Pincer.Session.Registry, "cli_user") do
      [{_, _}] -> :ok
      [] -> Pincer.Session.Server.start_link(session_id: "cli_user")
    end
    
    {:reply, :ok, %{state | frontend_pid: from_pid}}
  end

  # Interface do Dispatcher (necessária pelo Behaviour)
  def send_message(_chat_id, text) do
    GenServer.cast(__MODULE__, {:dispatch, text})
    :ok
  end

  # Recebe input do usuário vindo do frontend (remoto ou local)
  def handle_cast({:user_input, text}, state) do
    # Envia para a sessão
    Pincer.Session.Server.process_input("cli_user", text)
    {:noreply, state}
  end

  # Compatibilidade com código antigo e novos dispatches
  def handle_cast({:dispatch, text}, state) do
    send_to_frontend(state, text)
    {:noreply, state}
  end

  # --- Recebendo eventos do Core via PubSub ---

  def handle_info({:agent_response, text}, state) do
    send_to_frontend(state, text)
    {:noreply, state}
  end

  def handle_info({:agent_status, text}, state) do
    send_to_frontend(state, text)
    {:noreply, state}
  end

  def handle_info({:agent_thinking, text}, state) do
    send_to_frontend(state, text)
    {:noreply, state}
  end

  def handle_info({:agent_error, text}, state) do
    if state.frontend_pid do
      send(state.frontend_pid, {:cli_output, IO.ANSI.red() <> "[ERRO]: #{text}" <> IO.ANSI.reset()})
    else
      Logger.error("[CLI Error (Detached)]: #{text}")
    end
    {:noreply, state}
  end

  defp send_to_frontend(state, text) do
    if state.frontend_pid do
      send(state.frontend_pid, {:cli_output, text})
    else
      Logger.info("[CLI Output (Detached)]: #{text}")
    end
  end
end
