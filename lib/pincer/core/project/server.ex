defmodule Pincer.Core.Project.Server do
  @moduledoc """
  Independent GenServer for each project.
  Now with detailed error diagnostics and user-intervention flow.
  """
  use GenServer, restart: :transient
  require Logger

  alias Pincer.Core.Executor
  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Core.Project.Planner
  alias Pincer.Core.Project.Registry, as: ProjectRegistry

  def start_link(opts) do
    id = Keyword.get(opts, :id) || generate_id()
    GenServer.start_link(__MODULE__, opts, name: ProjectRegistry.via_tuple(id))
  end

  @impl true
  def init(opts) do
    id = Keyword.get(opts, :id) || generate_id()

    state = %{
      id: id,
      session_id: Keyword.fetch!(opts, :session_id),
      objective: Keyword.fetch!(opts, :objective),
      items: [],
      active_task_index: 0,
      status: :planning,
      worker_pid: nil,
      monitor_ref: nil,
      retry_count: 0,
      max_retries: Keyword.get(opts, :max_retries, 3),
      last_error: nil
    }

    send(self(), :plan_project)
    {:ok, state}
  end

  # --- API ---

  def get_status(id), do: GenServer.call(ProjectRegistry.via_tuple(id), :get_status)

  def approve(id), do: GenServer.call(ProjectRegistry.via_tuple(id), :approve)

  def pause(id), do: GenServer.call(ProjectRegistry.via_tuple(id), :pause)

  def resume(id), do: GenServer.call(ProjectRegistry.via_tuple(id), :resume)

  def stop(id), do: GenServer.stop(ProjectRegistry.via_tuple(id))

  def update_plan(id, tasks) when is_binary(tasks) do
    task_list =
      tasks
      |> String.split(~r/[\n,]/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    GenServer.call(ProjectRegistry.via_tuple(id), {:update_plan, task_list})
  end

  # --- Callbacks ---

  @impl true
  def handle_call(:get_status, _from, state), do: {:reply, {:ok, state}, state}

  @impl true
  def handle_call(:approve, _from, state) do
    Logger.info("[PROJECT] #{state.id} Approved. Starting execution.")
    Blackboard.post("system", "Project approved. Starting execution.", state.id)
    send(self(), :execute_next)
    {:reply, :ok, %{state | status: :running}}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    Logger.info("[PROJECT] #{state.id} Pausing execution.")
    {:reply, :ok, %{state | status: :paused}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    Logger.info("[PROJECT] #{state.id} Resuming execution.")
    Blackboard.post("system", "Project resumed.", state.id)
    send(self(), :execute_next)
    {:reply, :ok, %{state | status: :running, retry_count: 0}}
  end

  @impl true
  def handle_call({:update_plan, tasks}, _from, state) do
    Logger.info("[PROJECT] #{state.id} Updating plan with #{length(tasks)} tasks.")
    {:reply, :ok, %{state | items: tasks, active_task_index: 0, status: :awaiting_approval}}
  end

  @impl true
  def handle_info(:plan_project, state) do
    case Planner.build_plan(state.objective) do
      {:ok, tasks} ->
        Blackboard.post("Architect", "PLAN_GENERATED:\n" <> Enum.join(tasks, "\n"), state.id)
        {:noreply, %{state | items: tasks, status: :awaiting_approval}}

      {:error, reason} ->
        Logger.error("Failed to plan project: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info(:execute_next, %{status: status} = state) when status != :running,
    do: {:noreply, state}

  def handle_info(:execute_next, %{active_task_index: idx, items: items} = state)
      when idx >= length(items) do
    Blackboard.post("system", "Project completed successfully!", state.id)
    {:noreply, %{state | status: :completed}}
  end

  def handle_info(:execute_next, state) do
    task = Enum.at(state.items, state.active_task_index)
    role = extract_role(task)
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        history = [%{"role" => "user", "content" => task}]
        Executor.run(parent, state.session_id, history, project_id: state.id, role: role)
      end)

    ref = Process.monitor(pid)
    Blackboard.post("system", "Starting task (#{role}): #{task}", state.id)
    {:noreply, %{state | status: :running, worker_pid: pid, monitor_ref: ref}}
  end

  def handle_info({:executor_finished, _final_history, _result, _usage}, state) do
    if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])

    Blackboard.post(
      "system",
      "Completed: #{Enum.at(state.items, state.active_task_index)}",
      state.id
    )

    send(self(), :execute_next)

    {:noreply,
     %{
       state
       | active_task_index: state.active_task_index + 1,
         worker_pid: nil,
         monitor_ref: nil,
         retry_count: 0
     }}
  end

  def handle_info({:executor_failed, reason}, state) do
    handle_info({:DOWN, state.monitor_ref, :process, state.worker_pid, reason}, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state) do
    next_retry_count = state.retry_count + 1

    if next_retry_count < state.max_retries do
      Blackboard.post(
        "system",
        "Task failed, retrying... (Attempt #{next_retry_count})",
        state.id
      )

      send(self(), :execute_next)
      {:noreply, %{state | retry_count: next_retry_count, worker_pid: nil, monitor_ref: nil}}
    else
      diagnostic =
        "ERROR_DIAGNOSTIC: Task failed after #{state.max_retries} attempts. Last Reason: #{inspect(reason)}"

      Blackboard.post("Reviewer", diagnostic, state.id)

      Logger.error("Project #{state.id} halted. Awaiting user intervention.")

      {:noreply,
       %{
         state
         | status: :error,
           last_error: reason,
           retry_count: next_retry_count,
           worker_pid: nil,
           monitor_ref: nil
       }}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{worker_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Helpers ---
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
