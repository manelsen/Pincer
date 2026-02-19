defmodule Pincer.Core.Cron do
  @moduledoc """
  Gerencia tarefas agendadas do Pincer.
  Permite agendamentos simples (lembretes) e recorrentes.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{jobs: %{}}, name: __MODULE__)
  end

  @doc """
  Agenda uma mensagem ou tarefa para o futuro.
  """
  def schedule(session_id, message, seconds_from_now) do
    GenServer.cast(__MODULE__, {:schedule, session_id, message, seconds_from_now})
  end

  # Server Callbacks

  @impl true
  def init(state) do
    Logger.info("Sistema de Cron do Pincer iniciado.")
    {:ok, state}
  end

  @impl true
  def handle_cast({:schedule, session_id, message, seconds}, state) do
    Logger.info("Tarefa agendada para daqui a #{seconds}s: #{message}")
    
    # Usa Process.send_after para simplicidade no MVP
    # No futuro: persistir no SQLite para sobreviver a restarts
    Process.send_after(self(), {:trigger, session_id, message}, seconds * 1000)
    
    {:noreply, state}
  end

  @impl true
  def handle_info({:trigger, session_id, message}, state) do
    Logger.info("Trigger de Cron disparado para sessão #{session_id}")
    
    # Notifica a sessão. Se a sessão estiver offline, o Registry cuidará disso.
    case Registry.lookup(Pincer.Session.Registry, session_id) do
      [{pid, _}] ->
        send(pid, {:cron_trigger, message})
      [] ->
        Logger.warning("Sessão #{session_id} não encontrada para entregar mensagem de Cron.")
    end

    {:noreply, state}
  end
end
