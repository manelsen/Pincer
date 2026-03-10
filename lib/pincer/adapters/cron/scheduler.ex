defmodule Pincer.Adapters.Cron.Scheduler do
  @moduledoc """
  A lightweight GenServer-based cron scheduler that monitors and executes scheduled jobs.

  The Scheduler runs as a singleton process, checking for due jobs every 60 seconds.
  When a job's `next_run_at` timestamp is reached, it dispatches the job's prompt
  to the associated session and reschedules the job for its next execution time.

  ## Architecture

  The Scheduler follows a pull-based model:
  1. Every 60 seconds, queries `Pincer.Adapters.Cron.Storage` for due jobs
  2. For each due job, sends a `{:cron_trigger, prompt}` message to the target session
  3. If the session is not active, automatically wakes it up via `SessionSupervisor`
  4. Reschedules each job using the cron expression in `Pincer.Adapters.Cron.Storage`

  ## Supervision Tree

  The Scheduler should be started under your application's supervision tree:

      children = [
        Pincer.Adapters.Cron.Scheduler,
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
      GenServer.call(Pincer.Adapters.Cron.Scheduler, :status)

  ## Notes

  - Uses `Process.send_after/3` for tick scheduling (not `:timer.send_interval/3`)
  - Job execution is fire-and-forget; failures in session are handled by the session
  - The Scheduler is stateless; all job data is persisted in the database
  """
  use GenServer
  require Logger
  alias Pincer.Adapters.Cron.Storage

  @tick_interval :timer.seconds(60)
  @default_name __MODULE__

  @doc """
  Starts the Scheduler GenServer.

  The Scheduler registers itself with the name `Pincer.Adapters.Cron.Scheduler`.

  ## Parameters

    - `_opts` - Options passed to GenServer (currently unused)

  ## Returns

    - `{:ok, pid}` on successful start
    - `{:error, reason}` on failure

  ## Examples

      {:ok, pid} = Pincer.Adapters.Cron.Scheduler.start_link([])
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name, @default_name)
    server_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @impl true
  def init(opts) do
    tick_interval = Keyword.get(opts, :tick_interval, @tick_interval)

    state = %{
      tick_interval: tick_interval,
      due_jobs_fetcher: Keyword.get(opts, :due_jobs_fetcher, fn -> Storage.list_due_jobs() end),
      next_run_updater: Keyword.get(opts, :next_run_updater, &Storage.update_next_run!/1),
      job_dispatcher: Keyword.get(opts, :job_dispatcher, &deploy_job/1),
      missing_table_warned?: false
    }

    Logger.info("[Scheduler] Cron Scheduler started. First tick in #{tick_interval}ms.")

    send(self(), :tick)
    schedule_next_tick(tick_interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = process_due_jobs(state)
    schedule_next_tick(state.tick_interval)
    {:noreply, state}
  end

  defp schedule_next_tick(tick_interval) do
    Process.send_after(self(), :tick, tick_interval)
  end

  defp process_due_jobs(state) do
    {due_jobs, state} = load_due_jobs(state)

    if length(due_jobs) > 0 do
      Logger.info("[Scheduler] Found #{length(due_jobs)} due jobs in database! Dispatching...")
    end

    Enum.each(due_jobs, fn job ->
      state.job_dispatcher.(job)
      state.next_run_updater.(job)
    end)

    state
  end

  defp load_due_jobs(state) do
    {state.due_jobs_fetcher.(), state}
  rescue
    error ->
      if missing_cron_jobs_table?(error) do
        state = maybe_warn_missing_table(state)
        {[], state}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp missing_cron_jobs_table?(error) do
    msg = Exception.message(error)
    down = String.downcase(msg)

    (String.contains?(down, "no such table") or
       String.contains?(down, "undefined table") or
       String.contains?(down, "does not exist")) and String.contains?(down, "cron_jobs")
  rescue
    _ -> false
  end

  defp maybe_warn_missing_table(%{missing_table_warned?: true} = state), do: state

  defp maybe_warn_missing_table(state) do
    Logger.warning(
      "[Scheduler] cron_jobs table missing; scheduler will stay idle until migrations run."
    )

    %{state | missing_table_warned?: true}
  end

  defp deploy_job(job) do
    Logger.debug("[Scheduler] Dispatching Job #{job.id}: '#{job.name}' (To: #{job.session_id})")

    session_tuple = Registry.lookup(Pincer.Core.Session.Registry, job.session_id)

    case session_tuple do
      [{pid, _}] ->
        Logger.info("[Scheduler] Sending trigger to Active Session (#{job.session_id}).")
        send(pid, {:cron_trigger, job.prompt})

      [] ->
        Logger.info(
          "[Scheduler] Waking up hibernated session (#{job.session_id}) to trigger cron alarm."
        )

        case Pincer.Core.Session.Supervisor.start_session(job.session_id) do
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
