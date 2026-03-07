defmodule Pincer.Core.Orchestration.SubAgent do
  @moduledoc """
  An autonomous background agent that executes tasks independently and reports results.

  SubAgent implements the **autonomous worker** pattern in the Blackboard architecture.
  Each SubAgent operates as an independent GenServer that:

  1. Receives a specific goal to accomplish
  2. Spawns its own Executor with a specialized system prompt
  3. Runs without user interaction (fully autonomous)
  4. Reports all progress and final results to the Blackboard
  5. Terminates automatically upon completion or failure

  ## Architecture Role

      ┌─────────────────────────────────────────────────────────┐
      │                      Main Agent                         │
      │   (Coordinates SubAgents, polls Blackboard for results) │
      └──────────────────────────┬──────────────────────────────┘
                                 │ spawns
                    ┌────────────┼────────────┐
                    ▼            ▼            ▼
              ┌──────────┐ ┌──────────┐ ┌──────────┐
              │ SubAgent │ │ SubAgent │ │ SubAgent │
              │  (task1) │ │  (task2) │ │  (task3) │
              └────┬─────┘ └────┬─────┘ └────┬─────┘
                   │            │            │
                   └────────────┼────────────┘
                                ▼ posts results
                        ┌───────────────┐
                        │  Blackboard   │
                        └───────────────┘

  ## Autonomous Execution Model

  SubAgents are designed for "fire and forget" delegation:

  - **No user input**: The Executor receives a system prompt instructing it
    to complete tasks autonomously without asking for clarification
  - **Self-contained**: Each SubAgent has its own execution context
  - **Status broadcasting**: Tool usage and progress are posted to Blackboard
  - **Automatic termination**: Stops normally after reporting results

  ## Examples

      # Spawn a SubAgent to analyze a codebase
      {:ok, pid} = Pincer.Core.Orchestration.SubAgent.start_link(
        goal: "Analyze the authentication module and list all security vulnerabilities",
        id: "security_audit_001"
      )

      # Spawn with default auto-generated ID
      {:ok, pid} = Pincer.Core.Orchestration.SubAgent.start_link(
        goal: "Read the README.md and summarize the project purpose"
      )

      # Check results via Blackboard
      {messages, last_id} = Pincer.Core.Orchestration.Blackboard.fetch_new(0)

  ## Lifecycle

  1. **Initialization**: Posts "Started" to Blackboard, spawns Executor
  2. **Execution**: Executor runs autonomously, SubAgent forwards tool usage updates
  3. **Completion**: Posts "FINISHED: result" to Blackboard, stops normally
  4. **Failure**: Posts "FAILED: reason" to Blackboard, stops normally

  ## Message Flow

  The SubAgent receives the following messages from its Executor:

  - `{:executor_finished, history, response}` - Successful completion
  - `{:executor_failed, reason}` - Execution failure
  - `{:sme_tool_use, tools}` - Tool usage notification (forwarded to Blackboard)
  """

  use GenServer
  require Logger
  alias Pincer.Core.LLM.RuntimeStatus
  alias Pincer.Core.Executor
  alias Pincer.Core.Orchestration.Blackboard

  @type option :: {:goal, String.t()} | {:id, String.t()} | {:parent_session_id, String.t()}
  @type state :: %{id: String.t(), goal: String.t(), parent_session_id: String.t() | nil}

  @doc """
  Starts a new SubAgent with the given options.

  ## Options

    * `:goal` (required) - The task description for the SubAgent to accomplish
    * `:id` (optional) - Unique identifier for this SubAgent. Auto-generated if not provided

  ## Returns

    * `{:ok, pid}` - The SubAgent process was started successfully

  ## Examples

      iex> Pincer.Core.Orchestration.SubAgent.start_link(goal: "Count lines in lib/")
      {:ok, #PID<0.123.0>}

      iex> Pincer.Core.Orchestration.SubAgent.start_link(
      ...>   goal: "Find all TODOs",
      ...>   id: "todo_finder"
      ...> )
      {:ok, #PID<0.124.0>}

  """
  @spec start_link([option]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  @impl true
  def init(opts) do
    goal = Keyword.fetch!(opts, :goal)
    parent_session_id = Keyword.get(opts, :parent_session_id)
    id = Keyword.get(opts, :id, "sub_agent_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16()))

    Logger.info("[SubAgent #{id}] Starting with goal: #{goal}")

    # Post initial status
    Blackboard.post(id, "Started with goal: #{goal}")
    notify_parent(parent_session_id, "🤖 Sub-Agent [#{id}] started working on: #{goal}")


    # Start the Executor, passing *self()* as the session_pid
    # The Executor will send {:executor_finished, ...} to us.
    # We construct a history with the goal as the user prompt.
    history = [
      %{
        "role" => "system",
        "content" =>
          "You are a Sub-Agent. You have a specific goal. Do it autonomously using your tools. Do not ask for user input. Report your final result clearly."
      },
      %{"role" => "user", "content" => goal}
    ]

    Executor.start(self(), id, history)

    {:ok, %{id: id, goal: goal, parent_session_id: parent_session_id}}
  end

  # --- Handling Executor Messages ---

  @doc false
  @impl GenServer
  def handle_info({:executor_finished, _history, response, _usage}, state) do
    Logger.info("[SubAgent #{state.id}] Finished. Posting result.")
    Blackboard.post(state.id, "FINISHED: #{response}")
    notify_parent(state.parent_session_id, "✅ Sub-Agent [#{state.id}] finished: #{response}")
    {:stop, :normal, state}
  end

  @doc false
  @impl GenServer
  def handle_info({:executor_failed, reason}, state) do
    Logger.error("[SubAgent #{state.id}] Failed: #{inspect(reason)}")
    Blackboard.post(state.id, "FAILED: #{inspect(reason)}")
    notify_parent(state.parent_session_id, "❌ Sub-Agent [#{state.id}] failed: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  @doc false
  @impl GenServer
  def handle_info({:sme_tool_use, tools}, state) do
    Blackboard.post(state.id, "Using tool: #{tools}")
    notify_parent(state.parent_session_id, "⚙️ Sub-Agent [#{state.id}] using: #{tools}")
    {:noreply, state}
  end

  @doc false
  @impl GenServer
  def handle_info({:llm_runtime_status, payload}, state) when is_map(payload) do
    status = RuntimeStatus.format(payload)
    Blackboard.post(state.id, "LLM_STATUS: " <> status)
    notify_parent(state.parent_session_id, "📐 Sub-Agent [#{state.id}] status: #{status}")
    {:noreply, state}
  end

  @doc false
  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp notify_parent(nil, _msg), do: :ok
  defp notify_parent(session_id, msg) do
    Pincer.Infra.PubSub.broadcast("session:#{session_id}", {:agent_status, msg})
  end
end
