defmodule Pincer.Core.Project.Server do
  @moduledoc """
  Independent, durable GenServer for a project.

  Each state transition is persisted through `Pincer.Core.Project.Store`.
  A running project resumes from its persisted task index after a crash or VM
  restart; a task that was in flight is executed again (at-least-once), while
  completed tasks are never replayed.
  """
  use GenServer, restart: :transient
  require Logger

  alias Pincer.Core.Executor
  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Core.Project.Planner
  alias Pincer.Core.Project.Store
  alias Pincer.Core.Registry, as: CoreRegistry

  @kind "server"

  def start_link(opts) do
    id = Keyword.get(opts, :id) || generate_id()
    GenServer.start_link(__MODULE__, opts, name: via_tuple(id))
  end

  @impl true
  def init(opts) do
    id = Keyword.get(opts, :id) || generate_id()
    snapshot = load_snapshot(Keyword.get(opts, :id), opts)
    state = build_state(id, opts, snapshot)

    persist(state)

    case state.status do
      :running -> send(self(), :execute_next)
      :planning -> send(self(), :plan_project)
      _ -> :ok
    end

    {:ok, state}
  end

  # --- API ---

  @spec get_status(String.t()) :: {:ok, map()} | {:error, term()}
  def get_status(id) when is_binary(id) do
    case lookup(id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :get_status)
        catch
          :exit, _reason -> load_status(id)
        end

      [] ->
        load_status(id)
    end
  end

  @spec approve(String.t()) :: :ok | {:error, term()}
  def approve(id), do: call_started(id, :approve)

  @spec pause(String.t()) :: :ok | {:error, term()}
  def pause(id), do: call_started(id, :pause)

  @spec resume(String.t()) :: :ok | {:error, term()}
  def resume(id), do: call_started(id, :resume)

  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(id) when is_binary(id) do
    with {:ok, pid} <- ensure_started(id) do
      GenServer.call(pid, :stop)
    end
  end

  @spec update_plan(String.t(), String.t()) :: :ok | {:error, term()}
  def update_plan(id, tasks) when is_binary(tasks) do
    task_list =
      tasks
      |> String.split(~r/[\n,]/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    with {:ok, pid} <- ensure_started(id) do
      GenServer.call(pid, {:update_plan, task_list})
    end
  end

  @doc "Starts a persisted project if it is not already running."
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(id) when is_binary(id) do
    case lookup(id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        with {:ok, project} <- Store.load(id) do
          opts = [
            id: id,
            session_id: project.session_id,
            objective: snapshot_objective(project.payload)
          ]

          case Pincer.Core.Project.Supervisor.start_project(opts) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  @doc "Lists persisted projects, optionally filtered by session."
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    Store.list(Keyword.put(opts, :kind, @kind))
  end

  # --- Callbacks ---

  @impl true
  def handle_call(:get_status, _from, state), do: {:reply, {:ok, state}, state}

  @impl true
  def handle_call(:approve, _from, state) do
    Logger.info("[PROJECT] #{state.id} Approved. Starting execution.")

    state = %{state | status: :running, retry_count: 0, last_error: nil}
    persist(state)

    Blackboard.post("system", "Project approved. Starting execution.", state.id,
      scope: state.session_id
    )

    send(self(), :execute_next)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    Logger.info("[PROJECT] #{state.id} Pausing execution.")
    state = %{state | status: :paused}
    persist(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    Logger.info("[PROJECT] #{state.id} Resuming execution.")
    state = %{state | status: :running, retry_count: 0, last_error: nil}
    persist(state)

    Blackboard.post("system", "Project resumed.", state.id, scope: state.session_id)
    send(self(), :execute_next)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    Logger.info("[PROJECT] #{state.id} Stopped by user.")
    state = %{state | status: :stopped}
    persist(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_call({:update_plan, tasks}, _from, state) do
    Logger.info("[PROJECT] #{state.id} Updating plan with #{length(tasks)} tasks.")

    state = %{
      state
      | items: tasks,
        active_task_index: 0,
        status: :awaiting_approval,
        retry_count: 0,
        last_error: nil
    }

    persist(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:plan_project, state) do
    case Planner.build_plan(state.objective) do
      {:ok, tasks} ->
        state = %{state | items: tasks, status: :awaiting_approval, last_error: nil}
        persist(state)

        Blackboard.post("Architect", "PLAN_GENERATED:\n" <> Enum.join(tasks, "\n"), state.id,
          scope: state.session_id,
          kind: :plan_generated
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to plan project: #{inspect(reason)}")
        state = %{state | status: :error, last_error: reason}
        persist(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:execute_next, %{status: status} = state) when status != :running,
    do: {:noreply, state}

  def handle_info(:execute_next, %{active_task_index: idx, items: items} = state)
      when idx >= length(items) do
    state = %{state | status: :completed, worker_pid: nil, monitor_ref: nil}
    persist(state)

    Blackboard.post("system", "Project completed successfully!", state.id,
      scope: state.session_id
    )

    {:noreply, state}
  end

  def handle_info(:execute_next, state) do
    task_desc = Enum.at(state.items, state.active_task_index)
    role = extract_role(task_desc)
    parent = self()

    state = %{state | status: :running}
    persist(state)

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

    {:noreply, %{state | worker_pid: task.pid, monitor_ref: task.ref}}
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

    state = %{
      state
      | active_task_index: state.active_task_index + 1,
        worker_pid: nil,
        monitor_ref: nil,
        retry_count: 0
    }

    persist(state)
    send(self(), :execute_next)

    {:noreply, state}
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
      state = %{
        state
        | retry_count: next_retry_count,
          worker_pid: nil,
          monitor_ref: nil,
          last_error: reason
      }

      persist(state)

      Blackboard.post(
        "system",
        "Task failed, retrying... (Attempt #{next_retry_count})",
        state.id,
        scope: state.session_id
      )

      send(self(), :execute_next)
      {:noreply, state}
    else
      diagnostic =
        "ERROR_DIAGNOSTIC: Task failed after #{state.max_retries} attempts. Last Reason: #{inspect(reason)}"

      state = %{
        state
        | status: :error,
          last_error: reason,
          retry_count: next_retry_count,
          worker_pid: nil,
          monitor_ref: nil
      }

      persist(state)

      Blackboard.post("Reviewer", diagnostic, state.id,
        scope: state.session_id,
        kind: :error_diagnostic
      )

      Logger.error("Project #{state.id} halted. Awaiting user intervention.")
      {:noreply, state}
    end
  end

  defp call_started(id, message) do
    with {:ok, pid} <- ensure_started(id) do
      GenServer.call(pid, message)
    end
  end

  defp load_status(id) do
    case Store.load(id) do
      {:ok, %{kind: @kind} = project} -> {:ok, state_from_snapshot(id, project)}
      {:ok, _other} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup(id) do
    CoreRegistry.lookup(Pincer.Core.Project.Registry, id, :local)
  end

  defp load_snapshot(nil, _opts), do: nil

  defp load_snapshot(id, opts) do
    if Keyword.get(opts, :restore, true) do
      case Store.load(id) do
        {:ok, %{kind: @kind} = project} -> project
        _ -> nil
      end
    end
  end

  defp build_state(id, opts, nil) do
    %{
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
  end

  defp build_state(id, opts, project) do
    payload = project.payload

    %{
      id: id,
      session_id: Map.get(payload, :session_id, project.session_id),
      objective: Map.get(payload, :objective, Keyword.get(opts, :objective, "")),
      items: Map.get(payload, :items, []),
      active_task_index: Map.get(payload, :active_task_index, 0),
      status: project.status,
      worker_pid: nil,
      monitor_ref: nil,
      retry_count: Map.get(payload, :retry_count, 0),
      max_retries: Map.get(payload, :max_retries, Keyword.get(opts, :max_retries, 3)),
      last_error: Map.get(payload, :last_error)
    }
  end

  defp state_from_snapshot(id, project) do
    payload = project.payload

    %{
      id: id,
      session_id: Map.get(payload, :session_id, project.session_id),
      objective: Map.get(payload, :objective, ""),
      items: Map.get(payload, :items, []),
      active_task_index: Map.get(payload, :active_task_index, 0),
      status: project.status,
      worker_pid: nil,
      monitor_ref: nil,
      retry_count: Map.get(payload, :retry_count, 0),
      max_retries: Map.get(payload, :max_retries, 3),
      last_error: Map.get(payload, :last_error)
    }
  end

  defp snapshot_objective(payload) when is_map(payload), do: Map.get(payload, :objective, "")
  defp snapshot_objective(_payload), do: ""

  defp persist(state) do
    project = %{
      id: state.id,
      session_id: state.session_id,
      kind: @kind,
      status: state.status,
      payload: %{
        id: state.id,
        session_id: state.session_id,
        objective: state.objective,
        items: state.items,
        active_task_index: state.active_task_index,
        retry_count: state.retry_count,
        max_retries: state.max_retries,
        last_error: state.last_error
      }
    }

    case Store.save(project) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[PROJECT] #{state.id} persistence failed: #{inspect(reason)}")
        :error
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
