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
  alias Pincer.Core.Registry, as: CoreRegistry

  def start_link(opts) do
    id = Keyword.get(opts, :id) || generate_id()
    GenServer.start_link(__MODULE__, opts, name: via_tuple(id))
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

  def get_status(id), do: GenServer.call(via_tuple(id), :get_status)

  def approve(id), do: GenServer.call(via_tuple(id), :approve)

  def pause(id), do: GenServer.call(via_tuple(id), :pause)

  def resume(id), do: GenServer.call(via_tuple(id), :resume)

  def stop(id), do: GenServer.stop(via_tuple(id))

  def update_plan(id, tasks) when is_binary(tasks) do
    task_list =
      tasks
      |> String.split(~r/[\n,]/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    GenServer.call(via_tuple(id), {:update_plan, task_list})
  end

  # --- Callbacks ---

  @impl true
  def handle_call(:get_status, _from, state), do: {:reply, {:ok, state}, state}

  @impl true
  def handle_call(:approve, _from, state) do
    Logger.info("[PROJECT] #{state.id} Approved. Starting execution.")

    Blackboard.post("system", "Project approved. Starting execution.", state.id,
      scope: state.session_id
    )

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
    Blackboard.post("system", "Project resumed.", state.id, scope: state.session_id)
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
        Blackboard.post("Architect", "PLAN_GENERATED:\n" <> Enum.join(tasks, "\n"), state.id,
          scope: state.session_id,
          kind: :plan_generated
        )

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
    Blackboard.post("system", "Project completed successfully!", state.id,
      scope: state.session_id
    )

    {:noreply, %{state | status: :completed}}
  end

  def handle_info(:execute_next, state) do
    task_desc = Enum.at(state.items, state.active_task_index)
    role = extract_role(task_desc)
    parent = self()

    task =
      Task.Supervisor.async_nolink(Pincer.Core.TaskSupervisor, fn ->
        history = [%{"role" => "user", "content" => task_desc}]

        Executor.run(parent, state.session_id, history,
          project_id: state.id,
          role: role,
          notify?: false
        )
      end)

    Blackboard.post("system", "Starting task (#{role}): #{task_desc}", state.id,
      scope: state.session_id
    )

    {:noreply, %{state | status: :running, worker_pid: task.pid, monitor_ref: task.ref}}
  end

  def handle_info({ref, {:ok, _final_history, _result, _usage}}, %{monitor_ref: ref} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    Blackboard.post(
      "system",
      "Completed: #{Enum.at(state.items, state.active_task_index)}",
      state.id,
      scope: state.session_id
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

  def handle_info({ref, {:error, reason}}, %{monitor_ref: ref} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    handle_task_failure(reason, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state)
      when is_reference(ref) do
    handle_task_failure(reason, state)
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.monitor_ref) do
      Process.demonitor(state.monitor_ref, [:flush])
    end

    if is_pid(state.worker_pid) and Process.alive?(state.worker_pid) do
      case Task.Supervisor.terminate_child(Pincer.Core.TaskSupervisor, state.worker_pid) do
        :ok -> :ok
        {:error, :not_found} -> Process.exit(state.worker_pid, :kill)
      end
    end

    :ok
  end

  # --- Helpers ---

  defp handle_task_failure(reason, state) do
    next_retry_count = state.retry_count + 1

    if next_retry_count < state.max_retries do
      Blackboard.post(
        "system",
        "Task failed, retrying... (Attempt #{next_retry_count})",
        state.id,
        scope: state.session_id
      )

      send(self(), :execute_next)
      {:noreply, %{state | retry_count: next_retry_count, worker_pid: nil, monitor_ref: nil}}
    else
      diagnostic =
        "ERROR_DIAGNOSTIC: Task failed after #{state.max_retries} attempts. Last Reason: #{inspect(reason)}"

      Blackboard.post("Reviewer", diagnostic, state.id,
        scope: state.session_id,
        kind: :error_diagnostic
      )

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

  defp extract_role(task) do
    case Regex.run(~r/^(\w+):/, task) do
      [_, role] -> String.downcase(role)
      _ -> "unknown"
    end
  end

  defp via_tuple(id), do: CoreRegistry.via_tuple(Pincer.Core.Project.Registry, id, :local)

  defp generate_id do
    "p-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end
end
