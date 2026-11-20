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

  The SubAgent supervises its Executor via `Task.Supervisor.async_nolink/2` and
  correlates its monitor `ref` on completion, error, or unexpected task exit:

  - `{ref, {:ok, history, response, usage}}` - Successful completion
  - `{ref, {:error, reason}}` - Execution failure
  - `{:DOWN, ref, :process, _pid, reason}` - Unexpected worker task crash
  - `{:sme_tool_use, tools}` - Tool usage notification (forwarded to Blackboard)
  """

  use GenServer, restart: :temporary
  require Logger
  alias Pincer.Core.AgentPaths
  alias Pincer.Core.LLM.RuntimeStatus
  alias Pincer.Core.Executor
  alias Pincer.Core.Orchestration.Blackboard

  @type option ::
          {:goal, String.t()}
          | {:id, String.t()}
          | {:parent_session_id, String.t()}
          | {:parent_workspace_path, String.t()}
          | {:scope, String.t()}
          | {:workspace_path, String.t()}
          | {:llm_client, module()}
          | {:tool_registry, module()}
          | {:storage, module()}

  @type state :: %{
          id: String.t(),
          goal: String.t(),
          parent_session_id: String.t() | nil,
          scope: String.t(),
          workspace_path: String.t(),
          worker_pid: pid() | nil,
          worker_ref: reference() | nil
        }

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

  @doc """
  Starts a SubAgent as a `:temporary` child under the given `DynamicSupervisor`.
  """
  @spec start_supervised([option], GenServer.server()) :: DynamicSupervisor.on_start_child()
  def start_supervised(opts, supervisor \\ Pincer.Core.Orchestration.SubAgentSupervisor) do
    DynamicSupervisor.start_child(supervisor, {__MODULE__, opts})
  end

  @doc false
  @impl true
  def init(opts) do
    goal = Keyword.fetch!(opts, :goal)
    parent_session_id = Keyword.get(opts, :parent_session_id)
    id = Keyword.get(opts, :id, "sub_agent_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16()))
    parent_workspace_path = Keyword.get(opts, :parent_workspace_path)
    scope = Keyword.get(opts, :scope, parent_session_id || id)
    workspace_path = Keyword.get(opts, :workspace_path, AgentPaths.workspace_root(id))

    AgentPaths.ensure_workspace!(
      workspace_path,
      bootstrap?: false,
      inherit_from: parent_workspace_path
    )

    Logger.info("[SubAgent #{id}] Starting with goal: #{goal}")

    # Post initial status
    Blackboard.post(id, "Started with goal: #{goal}", nil, scope: scope)
    notify_parent_progress(parent_session_id, %{agent_id: id, kind: :started, goal: goal})
    notify_parent(parent_session_id, "🤖 Sub-Agent [#{id}] started working on: #{goal}")

    history = [
      %{
        "role" => "system",
        "content" =>
          "You are a Sub-Agent. You have a specific goal. Do it autonomously using your tools. Do not ask for user input. Report your final result clearly."
      },
      %{"role" => "user", "content" => goal}
    ]

    executor_opts =
      [workspace_path: workspace_path, notify?: false]
      |> maybe_put_opt(:llm_client, Keyword.get(opts, :llm_client))
      |> maybe_put_opt(:tool_registry, Keyword.get(opts, :tool_registry))
      |> maybe_put_opt(:storage, Keyword.get(opts, :storage))

    parent = self()

    task =
      Task.Supervisor.async_nolink(Pincer.Core.TaskSupervisor, fn ->
        Executor.run(parent, id, history, executor_opts)
      end)

    {:ok,
     %{
       id: id,
       goal: goal,
       parent_session_id: parent_session_id,
       scope: scope,
       workspace_path: workspace_path,
       worker_pid: task.pid,
       worker_ref: task.ref
     }}
  end

  # --- Handling Executor Messages ---

  @doc false
  @impl GenServer
  def handle_info({ref, {:ok, _history, response, _usage}}, %{worker_ref: ref} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    Logger.info("[SubAgent #{state.id}] Finished. Posting result.")
    Blackboard.post(state.id, "FINISHED: #{response}", nil, scope: state.scope)

    notify_parent_progress(state.parent_session_id, %{
      agent_id: state.id,
      kind: :finished,
      result: response
    })

    notify_parent(state.parent_session_id, "✅ Sub-Agent [#{state.id}] finished: #{response}")
    {:stop, :normal, %{state | worker_pid: nil, worker_ref: nil}}
  end

  @doc false
  @impl GenServer
  def handle_info({ref, {:error, reason}}, %{worker_ref: ref} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    handle_worker_failure(reason, state)
  end

  @doc false
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worker_ref: ref} = state)
      when is_reference(ref) do
    handle_worker_failure(reason, state)
  end

  @doc false
  @impl GenServer
  def handle_info({:sme_tool_use, tools}, state) do
    Blackboard.post(state.id, "Using tool: #{tools}", nil, scope: state.scope)

    notify_parent_progress(state.parent_session_id, %{
      agent_id: state.id,
      kind: :tool,
      tool: to_string(tools)
    })

    notify_parent(state.parent_session_id, "⚙️ Sub-Agent [#{state.id}] using: #{tools}")
    {:noreply, state}
  end

  @doc false
  @impl GenServer
  def handle_info({:llm_runtime_status, payload}, state) when is_map(payload) do
    status = RuntimeStatus.format(payload)
    Blackboard.post(state.id, "LLM_STATUS: " <> status, nil, scope: state.scope)

    notify_parent_progress(state.parent_session_id, %{
      agent_id: state.id,
      kind: :llm_status,
      status: status
    })

    notify_parent(state.parent_session_id, "📐 Sub-Agent [#{state.id}] status: #{status}")
    {:noreply, state}
  end

  @doc false
  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @doc false
  @impl GenServer
  def terminate(_reason, state) do
    if is_reference(state.worker_ref) do
      Process.demonitor(state.worker_ref, [:flush])
    end

    if is_pid(state.worker_pid) and Process.alive?(state.worker_pid) do
      case Task.Supervisor.terminate_child(Pincer.Core.TaskSupervisor, state.worker_pid) do
        :ok -> :ok
        {:error, :not_found} -> Process.exit(state.worker_pid, :kill)
      end
    end

    :ok
  end

  defp handle_worker_failure(reason, state) do
    Logger.error("[SubAgent #{state.id}] Failed: #{inspect(reason)}")
    Blackboard.post(state.id, "FAILED: #{inspect(reason)}", nil, scope: state.scope)

    notify_parent_progress(state.parent_session_id, %{
      agent_id: state.id,
      kind: :failed,
      reason: inspect(reason)
    })

    notify_parent(state.parent_session_id, "❌ Sub-Agent [#{state.id}] failed: #{inspect(reason)}")
    {:stop, :normal, %{state | worker_pid: nil, worker_ref: nil}}
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp notify_parent(nil, _msg), do: :ok

  defp notify_parent(session_id, msg) do
    Pincer.Infra.PubSub.broadcast("session:#{session_id}", {:agent_status, msg})
  end

  defp notify_parent_progress(nil, _event), do: :ok

  defp notify_parent_progress(session_id, event) do
    Pincer.Infra.PubSub.broadcast("session:#{session_id}", {:subagent_progress, event})
  end
end
