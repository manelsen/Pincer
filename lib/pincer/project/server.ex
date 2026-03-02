defmodule Pincer.Project.Server do
  @moduledoc """
  Independent GenServer for each project.
  Now with detailed error diagnostics and user-intervention flow.
  """
  use GenServer, restart: :transient
  require Logger

  alias Pincer.Project.Registry, as: ProjectRegistry
  alias Pincer.Orchestration.Blackboard
  alias Pincer.Project.Planner
  alias Pincer.Core.Executor

  def start_link(args) do
    id = Keyword.get(args, :id) || generate_id()
    GenServer.start_link(__MODULE__, args, name: ProjectRegistry.via_tuple(id))
  end

  # --- API ---
  def get_status(id), do: GenServer.call(ProjectRegistry.via_tuple(id), :get_status)
  def approve(id), do: GenServer.cast(ProjectRegistry.via_tuple(id), :approve_plan)
  def resume(id), do: GenServer.cast(ProjectRegistry.via_tuple(id), :resume)
  def stop(id), do: GenServer.stop(ProjectRegistry.via_tuple(id))

  # --- Callbacks ---

  @impl true
  def init(args) do
    session_id = Keyword.fetch!(args, :session_id)
    id = Keyword.get(args, :id) || generate_id()
    objective = Keyword.get(args, :objective)
    max_retries = Keyword.get(args, :max_retries, 3)

    state = %{
      id: id,
      session_id: session_id,
      objective: objective,
      status: :initializing,
      items: [],
      active_task_index: 0,
      worker_pid: nil,
      monitor_ref: nil,
      retry_count: 0,
      max_retries: max_retries,
      last_error: nil
    }

    {:ok, state, {:continue, :plan_and_catch_up}}
  end

  @impl true
  def handle_continue(:plan_and_catch_up, state) do
    {messages, _} = Blackboard.fetch_new(0)
    project_msgs = Enum.filter(messages, fn m -> m.project_id == state.id end)

    case find_completed_tasks_count(project_msgs) do
      0 ->
        case Planner.build_plan(state.objective) do
          {:ok, tasks} ->
            Blackboard.post("Architect", "PLAN_GENERATED:\n" <> Enum.join(tasks, "\n"), state.id)
            {:noreply, %{state | items: tasks, status: :awaiting_approval}}
          {:error, _} -> {:noreply, %{state | status: :error}}
        end
      count ->
        {:ok, tasks} = Planner.build_plan(state.objective)
        send(self(), :execute_next)
        {:noreply, %{state | items: tasks, active_task_index: count, status: :running}}
    end
  end

  @impl true
  def handle_cast(:approve_plan, state) do
    Blackboard.post("system", "Plan approved. Execution started.", state.id)
    send(self(), :execute_next)
    {:noreply, %{state | status: :running}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Blackboard.post("system", "Project resumed.", state.id)
    send(self(), :execute_next)
    {:noreply, %{state | status: :running, retry_count: 0}}
  end

  @impl true
  def handle_call(:get_status, _from, state), do: {:reply, {:ok, state}, state}

  # --- Handle Info (Grouped) ---

  @impl true
  def handle_info(:execute_next, %{status: status} = state) when status != :running, do: {:noreply, state}

  def handle_info(:execute_next, %{active_task_index: idx, items: items} = state) when idx >= length(items) do
    Blackboard.post("system", "Project completed successfully!", state.id)
    {:noreply, %{state | status: :completed}}
  end

  def handle_info(:execute_next, state) do
    task = Enum.at(state.items, state.active_task_index)
    role = extract_role(task)
    parent = self()
    
    {:ok, pid} = Task.start_link(fn -> 
      history = [%{"role" => "user", "content" => task}]
      Executor.run(parent, state.session_id, history, [project_id: state.id, role: role])
    end)

    ref = Process.monitor(pid)
    Blackboard.post("system", "Starting task (#{role}): #{task}", state.id)
    {:noreply, %{state | status: :running, worker_pid: pid, monitor_ref: ref}}
  end

  def handle_info({:executor_finished, _final_history, result}, state) do
    if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])
    Blackboard.post("system", "Completed: #{Enum.at(state.items, state.active_task_index)}", state.id)
    send(self(), :execute_next)
    {:noreply, %{state | active_task_index: state.active_task_index + 1, worker_pid: nil, monitor_ref: nil, retry_count: 0}}
  end

  def handle_info({:executor_failed, reason}, state) do
    # Captura o motivo específico da falha do executor (ex: 429, tool error)
    handle_info({:DOWN, state.monitor_ref, :process, state.worker_pid, reason}, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state) do
    if state.retry_count < state.max_retries do
      Blackboard.post("system", "Task failed, retrying... (Attempt #{state.retry_count + 1})", state.id)
      send(self(), :execute_next)
      {:noreply, %{state | retry_count: state.retry_count + 1, worker_pid: nil, monitor_ref: nil}}
    else
      # GERAÇÃO DO POST-MORTEM
      diagnostic = "ERROR_DIAGNOSTIC: Task failed after #{state.max_retries} attempts. Last Reason: #{inspect(reason)}"
      Blackboard.post("Reviewer", diagnostic, state.id)
      
      Logger.error("Project #{state.id} halted. Awaiting user intervention.")
      {:noreply, %{state | status: :error, last_error: reason, worker_pid: nil, monitor_ref: nil}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- Helpers ---
  defp find_completed_tasks_count(messages) do
    messages 
    |> Enum.filter(fn m -> String.contains?(m.content, "Completed:") end)
    |> length()
  end

  defp extract_role(task) do
    case Regex.run(~r/^(\w+):/, task) do
      [_, role] -> String.downcase(role)
      _ -> "unknown"
    end
  end

  defp generate_id do
    "p-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end
end
