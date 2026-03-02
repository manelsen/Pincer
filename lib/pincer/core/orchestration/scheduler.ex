defmodule Pincer.Core.Orchestration.Scheduler do
  @moduledoc """
  A time-based task orchestrator that executes recurring tasks defined in `HEARTBEAT.md`.

  The Scheduler implements a **declarative scheduling pattern** where tasks are defined
  in a markdown file rather than code. This enables:

  - **User-editable schedules**: Tasks can be added/removed by editing HEARTBEAT.md
  - **Persistence across restarts**: Schedules survive process restarts
  - **Human-readable configuration**: Markdown format is accessible to non-developers

  ## Task Definition Format

  Tasks are defined as checkbox items with interval annotations:

      ```markdown
      - [ ] Check for new emails (every 30m)
      - [ ] Sync database with remote (every 1h)
      - [ ] Run health check (every 5m)
      ```

  ### Interval Units

  | Unit | Meaning | Example |
  |------|---------|---------|
  | `s`  | Seconds | `(every 30s)` |
  | `m`  | Minutes | `(every 15m)` |
  | `h`  | Hours   | `(every 2h)` |

  ## Architecture

      ┌─────────────────────────────────────────────────────────────┐
      │                      HEARTBEAT.md                           │
      │  - [ ] Task description (every X<unit>)                     │
      │  - [ ] Another task (every Y<unit>)                         │
      └─────────────────────────┬───────────────────────────────────┘
                                │ reads every 60s
                                ▼
      ┌─────────────────────────────────────────────────────────────┐
      │                       SCHEDULER                             │
      │  ┌─────────────────────────────────────────────────────┐   │
      │  │ TaskState: {description, interval, last_run_at}     │   │
      │  └─────────────────────────────────────────────────────┘   │
      └─────────────────────────┬───────────────────────────────────┘
                                │ triggers when due
                                ▼
      ┌─────────────────────────────────────────────────────────────┐
      │                    Session Server                           │
      │  receives {:scheduler_trigger, description}                 │
      └─────────────────────────────────────────────────────────────┘

  ## Execution Flow

  1. **Tick**: Every 60 seconds, the Scheduler reads HEARTBEAT.md
  2. **Parse**: Each line is parsed for task pattern `"- [ ] desc (every X<unit>)"`
  3. **Check**: For each task, compare `current_time - last_run_at` against interval
  4. **Trigger**: If due, send `{:scheduler_trigger, description}` to Session
  5. **Update**: Record the trigger time for the task

  ## Examples

      # Start the Scheduler for a session
      {:ok, _pid} = Pincer.Core.Orchestration.Scheduler.start_link(
        session_id: "session_123"
      )

      # HEARTBEAT.md content:
      # - [ ] Check API status (every 5m)
      # - [ ] Generate daily report (every 24h)

  ## Notes

  - Tasks are identified by their description text (must be unique)
  - The Scheduler is registered under its module name
  - Tick interval is fixed at 60 seconds
  - Tasks are triggered via message passing to the Session Registry
  """

  use GenServer
  require Logger

  @heartbeat_file "HEARTBEAT.md"
  @check_interval :timer.seconds(60)

  defmodule TaskState do
    @moduledoc """
    Holds the runtime state for a scheduled task.

    ## Fields

      * `:description` - The task description (used as unique identifier)
      * `:interval_seconds` - Time between executions in seconds
      * `:last_run_at` - Unix timestamp of last execution (0 if never run)
    """
    @type t :: %__MODULE__{
            description: String.t(),
            interval_seconds: pos_integer(),
            last_run_at: non_neg_integer()
          }
    defstruct [:description, :interval_seconds, :last_run_at]
  end

  @type option :: {:session_id, String.t()}
  @type state :: %{
          session_id: String.t(),
          tasks: %{String.t() => TaskState.t()}
        }

  # Client API

  @doc """
  Starts the Scheduler GenServer for a specific session.

  The Scheduler will immediately begin monitoring HEARTBEAT.md for tasks
  and trigger them at their specified intervals.

  ## Options

    * `:session_id` (required) - The session ID to send trigger messages to

  ## Returns

    * `{:ok, pid}` - The Scheduler process started successfully

  ## Examples

      iex> Pincer.Core.Orchestration.Scheduler.start_link(session_id: "session_abc")
      {:ok, #PID<0.150.0>}

  """
  @spec start_link([option]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.get(opts, :session_id)
    Logger.info("[SCHEDULER] 🕰️ Started for Session #{session_id}")

    state = %{
      session_id: session_id,
      tasks: %{}
    }

    schedule_next_tick()

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    new_state = process_heartbeat_file(state)
    schedule_next_tick()
    {:noreply, new_state}
  end

  defp schedule_next_tick do
    Process.send_after(self(), :tick, @check_interval)
  end

  defp process_heartbeat_file(state) do
    if File.exists?(@heartbeat_file) do
      content = File.read!(@heartbeat_file)
      lines = String.split(content, "\n")

      Enum.reduce(lines, state, fn line, acc_state ->
        process_line(line, acc_state)
      end)
    else
      state
    end
  end

  defp process_line(line, state) do
    regex = ~r/^\s*-\s*\[\s*\]\s*(.+?)\s*\(every\s*(\d+)([smh])\)/i

    case Regex.run(regex, line) do
      [_, desc, val, unit] ->
        interval_sec = parse_interval(String.to_integer(val), unit)
        check_and_run_task(desc, interval_sec, state)

      _ ->
        state
    end
  end

  @spec parse_interval(pos_integer(), String.t()) :: pos_integer()
  defp parse_interval(val, "s"), do: val
  defp parse_interval(val, "m"), do: val * 60
  defp parse_interval(val, "h"), do: val * 3600
  defp parse_interval(_, _), do: 86400

  defp check_and_run_task(description, interval, state) do
    now = System.system_time(:second)

    task_state =
      Map.get(state.tasks, description, %TaskState{
        description: description,
        interval_seconds: interval,
        last_run_at: 0
      })

    if now - task_state.last_run_at >= interval do
      trigger_task(state.session_id, description)

      new_task_state = %{task_state | last_run_at: now}
      %{state | tasks: Map.put(state.tasks, description, new_task_state)}
    else
      %{state | tasks: Map.put(state.tasks, description, task_state)}
    end
  end

  defp trigger_task(session_id, description) do
    Logger.info("[SCHEDULER] 🚀 Triggering task: #{description}")

    case Registry.lookup(Pincer.Core.Session.Registry, session_id) do
      [{pid, _}] ->
        send(pid, {:scheduler_trigger, description})

      _ ->
        Logger.warning("[SCHEDULER] Session #{session_id} not found!")
    end
  end
end
