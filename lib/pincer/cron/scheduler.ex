defmodule Pincer.Cron.Scheduler do
  @moduledoc """
  A lightweight GenServer-based cron scheduler that monitors and executes scheduled jobs.

  The Scheduler runs as a singleton process, checking for due jobs every 60 seconds.
  When a job's `next_run_at` timestamp is reached, it dispatches the job's prompt
  to the associated session and reschedules the job for its next execution time.

  ## Architecture

  The Scheduler follows a pull-based model:
  1. Every 60 seconds, queries `Pincer.Cron.Storage` for due jobs
  2. For each due job, sends a `{:cron_trigger, prompt}` message to the target session
  3. If the session is not active, automatically wakes it up via `SessionSupervisor`
  4. Reschedules each job using the cron expression in `Pincer.Cron.Storage`

  ## Supervision Tree

  The Scheduler should be started under your application's supervision tree:

      children = [
        Pincer.Cron.Scheduler,
        # ... other children
      ]

  ## Session Wake-up Behavior

  When a cron job targets a hibernated session:
  - The Scheduler attempts to start the session via `SessionSupervisor.start_child/2`
  - If already started (race condition), retrieves the existing PID
  - Sends `{:cron_trigger, prompt}` to the session for processing

  ## Examples

      # Jobs are automatically processed every 60 seconds
      # No manual intervention required after Scheduler starts

      # To check Scheduler status (if monitoring is added):
      GenServer.call(Pincer.Cron.Scheduler, :status)

  ## Notes

  - Uses `Process.send_after/3` for tick scheduling (not `:timer.send_interval/3`)
  - Job execution is fire-and-forget; failures in session are handled by the session
  - The Scheduler is stateless; all job data is persisted in the database
  """
  use GenServer
  require Logger
  alias Pincer.Cron.Storage

  @tick_interval :timer.seconds(60)

  @doc """
  Starts the Scheduler GenServer.

  The Scheduler registers itself with the name `Pincer.Cron.Scheduler`.

  ## Parameters

    - `_opts` - Options passed to GenServer (currently unused)

  ## Returns

    - `{:ok, pid}` on successful start
    - `{:error, reason}` on failure

  ## Examples

      {:ok, pid} = Pincer.Cron.Scheduler.start_link([])
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Logger.info("[Scheduler] Cron Scheduler started. First tick in #{@tick_interval}ms.")

    schedule_next_tick()
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    process_due_jobs()
    schedule_next_tick()
    {:noreply, state}
  end

  defp schedule_next_tick do
    Process.send_after(self(), :tick, @tick_interval)
  end

  defp process_due_jobs do
    due_jobs = Storage.list_due_jobs()

    if length(due_jobs) > 0 do
      Logger.info("[Scheduler] Found #{length(due_jobs)} due jobs in database! Dispatching...")
    end

    Enum.each(due_jobs, fn job ->
      deploy_job(job)
      Storage.update_next_run!(job)
    end)
  end

  defp deploy_job(job) do
    Logger.debug("[Scheduler] Dispatching Job #{job.id}: '#{job.name}' (To: #{job.session_id})")

    session_tuple = Registry.lookup(Pincer.Session.Registry, job.session_id)

    case session_tuple do
      [{pid, _}] ->
        Logger.info("[Scheduler] Sending trigger to Active Session (#{job.session_id}).")
        send(pid, {:cron_trigger, job.prompt})

      [] ->
        Logger.info(
          "[Scheduler] Waking up hibernated session (#{job.session_id}) to trigger cron alarm."
        )

        case Pincer.Session.Supervisor.start_session(job.session_id) do
          {:ok, pid} ->
            send(pid, {:cron_trigger, job.prompt})

          {:error, {:already_started, pid}} ->
            send(pid, {:cron_trigger, job.prompt})

          error ->
            Logger.error("[Scheduler] Failed to wake session for Cron Trigger: #{inspect(error)}")
        end
    end
  end
end
