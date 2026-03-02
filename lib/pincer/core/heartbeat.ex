defmodule Pincer.Core.Heartbeat do
  @moduledoc """
  Pincer's periodic heartbeat.
  Wakes up the agent proactively to check world status (ex: GitHub).
  """
  use GenServer
  require Logger

  # Heartbeat interval (ex: 1 hour)
  @interval 60 * 60 * 1000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Logger.info("Pincer's heart started beating.")
    schedule_pulse()
    {:ok, state}
  end

  @impl true
  def handle_info(:pulse, state) do
    Logger.info("[HEARTBEAT] Pulse detected. Checking proactivity...")

    # Example of proactive task: Notify Manel that Pincer is alert.
    # In the future, a specific Worker will be called here to fetch news from GitHub.
    # Dispatcher.dispatch("telegram_924255495", "⚙️ Routine pulse: systems operational. Any tasks for now, Manel?")

    schedule_pulse()
    {:noreply, state}
  end

  defp schedule_pulse do
    Process.send_after(self(), :pulse, @interval)
  end
end
