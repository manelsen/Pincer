defmodule Pincer.Core.Session.TaskCoordinator do
  @moduledoc """
  Coordinates supervised executor and unsolicited-evaluation tasks for a session:
  spawning, reference correlation, interruption, trace reporting, and lifecycle cleanup.
  """

  require Logger

  alias Pincer.Core.Executor
  alias Pincer.Core.Introspection
  alias Pincer.Core.Session.Blackboard, as: SessionBlackboard
  alias Pincer.Core.Session.ErrorUX
  alias Pincer.Core.Session.History, as: SessionHistory
  alias Pincer.Core.Session.Preferences
  alias Pincer.Core.Telemetry
  alias Pincer.Infra.PubSub
  alias PincerPorts.Structs.Usage

  @task_supervisor Pincer.Core.TaskSupervisor

  @doc """
  Persists user `input`, appends the normalized user message to history, and
  spawns a supervised executor turn.
  """
  @spec start_standard_turn(map(), term(), keyword()) :: map()
  def start_standard_turn(state, input, opts \\ []) do
    history_mod = Keyword.get(opts, :history_mod, SessionHistory)
    history_mod.persist_user_input(state.session_id, input, state.workspace_path)
    user_msg = history_mod.build_user_message(input, state.workspace_path)
    start_turn(state, state.history ++ [user_msg], opts)
  end

  @doc """
  Spawns a supervised `Executor.run/4` task for `history` and updates worker
  tracking fields in `state`.
  """
  @spec start_turn(map(), [map()], keyword()) :: map()
  def start_turn(state, history, opts \\ []) do
    task_supervisor = Keyword.get(opts, :task_supervisor, @task_supervisor)
    executor = Keyword.get(opts, :executor, Executor)
    kernel = Keyword.get(opts, :kernel, Introspection.Kernel)
    telemetry = Keyword.get(opts, :telemetry, Telemetry)
    parent = Keyword.get(opts, :parent, self())

    executor_opts =
      [
        agent_id: state.root_agent_id,
        model_override: model_override_with_thinking(state),
        workspace_path: state.workspace_path,
        trace_events?: true,
        notify?: false
      ]
      |> maybe_put_opt(:channel, Map.get(state, :channel))
      |> maybe_put_opt(:conversation_ref, Map.get(state, :conversation_ref))
      |> maybe_put_opt(:llm_client, state.llm_client)

    turn_start_ms = telemetry.emit_conversation_turn_start(state.session_id)

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        executor.run(parent, state.session_id, history, executor_opts)
      end)

    lesson_ids = kernel.get_lesson_ids(state.root_agent_id)
    kernel.report_activity(state.root_agent_id, :working)

    %{
      state
      | history: history,
        worker_pid: task.pid,
        worker_ref: task.ref,
        status: :working,
        injected_lesson_ids: lesson_ids,
        turn_start_ms: turn_start_ms
    }
  end

  @doc """
  Spawns a supervised unsolicited evaluation task (`:bootstrap` or `:blackboard`)
  and tracks its monitor reference in `state.pending_evals`.
  """
  @spec start_unsolicited_eval(map(), [map()], atom(), keyword()) :: map()
  def start_unsolicited_eval(state, history, kind, opts \\ []) do
    task_supervisor = Keyword.get(opts, :task_supervisor, @task_supervisor)
    evaluator = Keyword.get(opts, :evaluator, &SessionBlackboard.evaluate_update/3)
    eval_opts = maybe_put_opt([], :llm_client, state.llm_client)
    model_override = state.model_override

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        evaluator.(history, model_override, eval_opts)
      end)

    %{state | pending_evals: Map.put(state.pending_evals, task.ref, kind)}
  end

  @doc """
  Handles correlated task outcome and `:DOWN` messages for the active executor
  worker or pending unsolicited evaluations. Returns `{:handled, new_state}` or
  `:ignore`.
  """
  @spec handle_task_message(term(), map(), keyword()) :: {:handled, map()} | :ignore
  def handle_task_message(msg, state, opts \\ [])

  def handle_task_message(
        {ref, {:ok, final_history, response, usage}},
        %{worker_ref: ref} = state,
        opts
      )
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    history_mod = Keyword.get(opts, :history_mod, SessionHistory)
    preferences_mod = Keyword.get(opts, :preferences_mod, Preferences)
    kernel = Keyword.get(opts, :kernel, Introspection.Kernel)
    telemetry = Keyword.get(opts, :telemetry, Telemetry)
    publish_fn = publish_fn(opts)

    history_mod.persist_assistant_response(state.session_id, response)
    normalized_usage = Usage.normalize(usage)
    new_totals = Usage.add(state.token_usage_total, normalized_usage)

    publish_fn.(state.session_id, {:agent_response, response, usage})
    kernel.report_activity(state.root_agent_id, :idle)

    if state.turn_start_ms do
      telemetry.emit_conversation_turn_stop(state.session_id, state.turn_start_ms, %{
        prompt_tokens: normalized_usage.prompt_tokens,
        completion_tokens: normalized_usage.completion_tokens
      })
    end

    new_state = %{
      state
      | history: history_mod.prune(final_history, state.session_id),
        status: :idle,
        worker_pid: nil,
        worker_ref: nil,
        token_usage_total: new_totals,
        turn_start_ms: nil
    }

    preferences_mod.save_state(new_state)
    {:handled, new_state}
  end

  def handle_task_message({ref, {:error, reason}}, %{worker_ref: ref} = state, opts)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:handled, handle_executor_failure(reason, state, opts)}
  end

  def handle_task_message({:DOWN, ref, :process, _pid, reason}, %{worker_ref: ref} = state, opts)
      when is_reference(ref) do
    {:handled, handle_executor_failure(reason, state, opts)}
  end

  def handle_task_message({ref, {:reply, response, usage}}, state, opts)
      when is_reference(ref) and is_map_key(state.pending_evals, ref) do
    Process.demonitor(ref, [:flush])
    history_mod = Keyword.get(opts, :history_mod, SessionHistory)
    preferences_mod = Keyword.get(opts, :preferences_mod, Preferences)
    publish_fn = publish_fn(opts)

    history_mod.persist_assistant_response(state.session_id, response)
    normalized_usage = Usage.normalize(usage)
    new_totals = Usage.add(state.token_usage_total, normalized_usage)
    new_history = state.history ++ [%{"role" => "assistant", "content" => response}]

    new_state = %{
      state
      | history: new_history,
        token_usage_total: new_totals,
        pending_evals: Map.delete(state.pending_evals, ref)
    }

    preferences_mod.save_state(new_state)
    publish_fn.(state.session_id, {:agent_response, response, usage})
    {:handled, new_state}
  end

  def handle_task_message({ref, :ignore}, state, _opts)
      when is_reference(ref) and is_map_key(state.pending_evals, ref) do
    Process.demonitor(ref, [:flush])
    {:handled, %{state | pending_evals: Map.delete(state.pending_evals, ref)}}
  end

  def handle_task_message({ref, {:error, reason}}, state, _opts)
      when is_reference(ref) and is_map_key(state.pending_evals, ref) do
    Process.demonitor(ref, [:flush])

    Logger.error(
      "[SESSION] #{state.session_id} evaluate_blackboard_update failed: #{inspect(reason)}"
    )

    {:handled, %{state | pending_evals: Map.delete(state.pending_evals, ref)}}
  end

  def handle_task_message({:DOWN, ref, :process, _pid, reason}, state, _opts)
      when is_reference(ref) and is_map_key(state.pending_evals, ref) do
    Logger.error(
      "[SESSION] #{state.session_id} evaluate_blackboard_update crashed: #{inspect(reason)}"
    )

    {:handled, %{state | pending_evals: Map.delete(state.pending_evals, ref)}}
  end

  def handle_task_message(_msg, _state, _opts), do: :ignore

  @doc """
  Stops any running executor worker task and clears `worker_pid` and `worker_ref`.
  """
  @spec stop_worker(map(), keyword()) :: map()
  def stop_worker(state, opts \\ []) do
    task_supervisor = Keyword.get(opts, :task_supervisor, @task_supervisor)

    if is_reference(state.worker_ref) do
      Process.demonitor(state.worker_ref, [:flush])
    end

    if worker_alive?(state) do
      case Task.Supervisor.terminate_child(task_supervisor, state.worker_pid) do
        :ok -> :ok
        {:error, :not_found} -> Process.exit(state.worker_pid, :kill)
      end
    end

    %{state | worker_pid: nil, worker_ref: nil}
  end

  @doc """
  Demonitors and clears all tracked `pending_evals`.
  """
  @spec clear_pending_evals(map()) :: map()
  def clear_pending_evals(state) do
    Enum.each(state.pending_evals, fn {ref, _kind} ->
      if is_reference(ref), do: Process.demonitor(ref, [:flush])
    end)

    %{state | pending_evals: %{}}
  end

  @doc """
  Returns `true` when `state.worker_pid` points to a live process.
  """
  @spec worker_alive?(map()) :: boolean()
  def worker_alive?(%{worker_pid: pid}) when is_pid(pid), do: Process.alive?(pid)
  def worker_alive?(_state), do: false

  @doc """
  Notifies an active executor worker of a model hot-swap.
  """
  @spec notify_model_changed(map(), String.t(), String.t()) :: :ok
  def notify_model_changed(state, provider, model) do
    if worker_alive?(state), do: send(state.worker_pid, {:model_changed, provider, model})
    :ok
  end

  @doc """
  Delivers a tool approval decision (`:approved` | `:rejected`) to an active worker.
  """
  @spec send_approval_decision(map(), String.t(), :approved | :rejected) :: :ok
  def send_approval_decision(state, call_id, decision) do
    if worker_alive?(state),
      do: send(state.worker_pid, {:tool_approval_result, call_id, decision})

    :ok
  end

  @doc """
  Reports an executor trace to the introspection kernel and records lesson outcomes.
  """
  @spec record_trace(map(), map(), keyword()) :: map()
  def record_trace(state, trace_meta, opts \\ []) do
    kernel = Keyword.get(opts, :kernel, Introspection.Kernel)
    lesson_store = Keyword.get(opts, :lesson_store, Introspection.LessonStore)
    task_supervisor = Keyword.get(opts, :task_supervisor, @task_supervisor)

    kernel.report_trace(state.root_agent_id, trace_meta)

    maybe_update_lesson_outcomes(
      state.injected_lesson_ids,
      trace_meta,
      lesson_store,
      task_supervisor
    )

    %{state | last_executor_trace: trace_meta, injected_lesson_ids: []}
  end

  @doc """
  Attaches `state.thinking_level` to `state.model_override` when both are present.
  """
  @spec model_override_with_thinking(map()) :: map() | nil
  def model_override_with_thinking(%{thinking_level: level, model_override: override})
      when not is_nil(level) and is_map(override) do
    Map.put(override, :thinking_level, level)
  end

  def model_override_with_thinking(%{model_override: override}), do: override

  defp handle_executor_failure(reason, state, opts) do
    kernel = Keyword.get(opts, :kernel, Introspection.Kernel)
    telemetry = Keyword.get(opts, :telemetry, Telemetry)
    error_ux_mod = Keyword.get(opts, :error_ux_mod, ErrorUX)
    publish_fn = publish_fn(opts)

    Logger.error("[SESSION] #{state.session_id} Executor failed: #{inspect(reason)}")
    telemetry.emit_conversation_error(state.session_id, reason)
    kernel.report_activity(state.root_agent_id, :idle)

    error_msg = "❌ #{error_ux_mod.friendly(reason, scope: :executor)}"
    publish_fn.(state.session_id, {:agent_response, error_msg})

    %{state | status: :idle, worker_pid: nil, worker_ref: nil, turn_start_ms: nil}
  end

  defp maybe_update_lesson_outcomes([], _trace_meta, _lesson_store, _task_supervisor), do: :ok

  defp maybe_update_lesson_outcomes(lesson_ids, trace_meta, lesson_store, task_supervisor) do
    outcome = trace_outcome(trace_meta)

    Task.Supervisor.start_child(task_supervisor, fn ->
      Enum.each(lesson_ids, fn id ->
        lesson_store.record_outcome(id, outcome)
      end)
    end)

    :ok
  end

  defp trace_outcome(trace_meta) do
    steps = trace_meta[:steps] || trace_meta["steps"] || []

    has_error? =
      Enum.any?(steps, fn
        %{kind: "error"} -> true
        %{"kind" => "error"} -> true
        _ -> false
      end)

    if has_error?, do: :failure, else: :success
  end

  defp publish_fn(opts) do
    Keyword.get(opts, :publish_fn, fn sid, event -> PubSub.broadcast("session:#{sid}", event) end)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
