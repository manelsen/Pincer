defmodule Pincer.Core.Cron do
  @moduledoc """
  Manages scheduled tasks for Pincer.
  Allows simple scheduling (reminders) and recurring tasks.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{jobs: %{}}, name: __MODULE__)
  end

  @doc """
  Schedules a message or task for the future.
  """
  def schedule(session_id, message, seconds_from_now) do
    GenServer.cast(__MODULE__, {:schedule, session_id, message, seconds_from_now})
  end

  # Server Callbacks

  @impl true
  def init(state) do
    Logger.info("Pincer Cron system started.")
    {:ok, state}
  end

  @impl true
  def handle_cast({:schedule, session_id, message, seconds}, state) do
    Logger.info("Task scheduled for #{seconds}s from now: #{message}")

    # Uses Process.send_after for simplicity in MVP
    # In the future: persist to SQLite to survive restarts
    Process.send_after(self(), {:trigger, session_id, message}, seconds * 1000)

    {:noreply, state}
  end

  @impl true
  def handle_info({:trigger, session_id, message}, state) do
    Logger.info("Cron trigger fired for session #{session_id}")

    # Notifies the session. If the session is offline, the Registry will handle it.
    case Registry.lookup(Pincer.Session.Registry, session_id) do
      [{pid, _}] ->
        send(pid, {:cron_trigger, message})

      [] ->
        Logger.warning("Session #{session_id} not found to deliver Cron message.")
    end

    {:noreply, state}
  end
end
