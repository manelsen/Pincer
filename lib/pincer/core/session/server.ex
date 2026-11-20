defmodule Pincer.Core.Session.Server do
  @moduledoc """
  Core session GenServer implementing the Pincer Brain (The Maestro).

  The Maestro orchestrates conversation lifecycle, manages supervised executor
  and unsolicited-evaluation tasks via `Task.Supervisor.async_nolink/2` with
  reference correlation, and delegates persistence, prompt rendering, tool
  approvals, and Blackboard ingestion to focused `Session.*` / `PromptAssembly`
  modules.
  """
  use GenServer, restart: :transient
  require Logger

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.AlignmentIntegrity
  alias Pincer.Core.ErrorUX
  alias Pincer.Core.Executor
  alias Pincer.Core.Introspection
  alias Pincer.Core.Orchestration.Archivist
  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Core.ProjectRouter
  alias Pincer.Core.PromptAssembly
  alias Pincer.Core.Registry, as: CoreRegistry
  alias Pincer.Core.Session.Approval, as: SessionApproval
  alias Pincer.Core.Session.Blackboard, as: SessionBlackboard
  alias Pincer.Core.Session.History, as: SessionHistory
  alias Pincer.Core.Session.Preferences
  alias Pincer.Core.Structs.IncomingMessage
  alias Pincer.Core.Structs.Usage
  alias Pincer.Core.Telemetry
  alias Pincer.Infra.PubSub
  alias Pincer.Ports.Storage

  @task_supervisor Pincer.Core.TaskSupervisor

  @doc false
  defdelegate bootstrap_active?(workspace_path, opts \\ []), to: PromptAssembly

  # --- Public API ---

  @doc """
  Starts a supervised session GenServer registered locally by `opts[:session_id]`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:session_id]))

  @doc """
  Queues or processes an incoming user message or approval response for `id`.
  """
  @spec process_input(String.t(), IncomingMessage.t() | String.t()) :: term()
  def process_input(id, input), do: GenServer.call(via_tuple(id), {:process_input, input})

  @doc """
  Returns the current `{:ok, state}` snapshot for session `id`.
  """
  @spec get_status(String.t()) :: {:ok, map()}
  def get_status(id), do: GenServer.call(via_tuple(id), :get_status)

  @doc """
  Resets persisted and in-memory conversation history for session `id`.
  """
  @spec reset(String.t()) :: :ok
  def reset(id), do: GenServer.call(via_tuple(id), :reset)

  @doc """
  Updates the session's active LLM `provider` and `model` override, notifying any running worker.
  """
  @spec set_model(String.t(), String.t(), String.t()) :: :ok
  def set_model(id, provider, model),
    do: GenServer.call(via_tuple(id), {:set_model, provider, model}, 15_000)

  @doc """
  Sets the session thinking level preference.
  """
  @spec set_thinking(String.t(), String.t() | nil) :: :ok
  def set_thinking(id, level), do: GenServer.call(via_tuple(id), {:set_thinking, level})

  @doc """
  Toggles visibility of model reasoning tokens for session `id`.
  """
  @spec set_reasoning_visible(String.t(), boolean()) :: :ok
  def set_reasoning_visible(id, visible),
    do: GenServer.call(via_tuple(id), {:set_reasoning_visible, visible})

  @doc """
  Toggles verbose runtime notifications (such as failover notices) for session `id`.
  """
  @spec set_verbose(String.t(), boolean()) :: :ok
  def set_verbose(id, verbose), do: GenServer.call(via_tuple(id), {:set_verbose, verbose})

  @doc """
  Sets token usage footer display mode for session `id`.
  """
  @spec set_usage(String.t(), term()) :: :ok
  def set_usage(id, level), do: GenServer.call(via_tuple(id), {:set_usage, level})

  @doc """
  Enables auto-approval for privileged tools for `duration_seconds`.
  """
  @spec approve_all(String.t(), pos_integer()) :: :ok
  def approve_all(id, duration_seconds \\ 600),
    do: GenServer.call(via_tuple(id), {:approve_all, duration_seconds})

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    root_agent_id = Keyword.get(opts, :root_agent_id, session_id)
    Logger.metadata(session_id: session_id)
    workspace_path = Keyword.get(opts, :workspace_path, AgentPaths.workspace_root(root_agent_id))
    bootstrap? = Keyword.get(opts, :bootstrap?, true)
    blackboard_scope = Keyword.get(opts, :blackboard_scope, root_agent_id)

    AgentPaths.ensure_workspace!(workspace_path, bootstrap?: bootstrap?)

    Introspection.Kernel.ensure_started(root_agent_id)
    Introspection.Kernel.register_session(root_agent_id, self())
    self_state = Introspection.Kernel.get_self_state(root_agent_id)

    verify_alignment_integrity(workspace_path, session_id)

    PubSub.subscribe("session:#{session_id}")
    PubSub.subscribe("system:updates")

    prefs = Preferences.load(workspace_path)

    if prefs.model_override do
      Logger.info(
        "[SESSION] #{session_id} loaded model preference: #{prefs.model_override.provider}:#{prefs.model_override.model}"
      )
    end

    watcher_pid = maybe_start_graph_watcher(workspace_path)

    system_prompt =
      PromptAssembly.build_system_prompt(
        workspace_path: workspace_path,
        root_agent_id: root_agent_id,
        self_state: self_state
      )

    {history, fresh?} = SessionHistory.load(session_id, system_prompt)

    state = %{
      mode: :normal,
      session_id: session_id,
      root_agent_id: root_agent_id,
      principal_ref: Keyword.get(opts, :principal_ref),
      conversation_ref: Keyword.get(opts, :conversation_ref),
      workspace_path: workspace_path,
      blackboard_scope: blackboard_scope,
      history: history,
      status: :idle,
      worker_pid: nil,
      worker_ref: nil,
      pending_evals: %{},
      last_blackboard_id: 0,
      subagent_progress_tracker: %{},
      model_override: prefs.model_override,
      thinking_level: prefs.thinking_level,
      reasoning_visible: prefs.reasoning_visible,
      verbose: false,
      usage_display: prefs.usage_display,
      token_usage_total: prefs.token_usage_total,
      input_buffer: [],
      debounce_timer: nil,
      llm_client: Keyword.get(opts, :llm_client),
      watcher_pid: watcher_pid,
      pending_approval: nil,
      auto_approve_until: nil,
      last_executor_trace: nil,
      self_state: self_state,
      injected_lesson_ids: [],
      turn_start_ms: nil
    }

    send(self(), :recovery_catch_up)

    if fresh? and PromptAssembly.bootstrap_active?(workspace_path) do
      send(self(), :trigger_bootstrap)
    end

    Process.send_after(self(), :heartbeat, 5000)
    Telemetry.emit_conversation_start(session_id, %{fresh: fresh?})

    {:ok, state}
  end

  # --- Supervised Task & Correlated Outcomes ---

  @impl true
  def handle_info({ref, {:ok, final_history, response, usage}}, %{worker_ref: ref} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    SessionHistory.persist_assistant_response(state.session_id, response)

    normalized_usage = Usage.normalize(usage)
    new_totals = Usage.add(state.token_usage_total, normalized_usage)

    publish(state.session_id, {:agent_response, response, usage})
    Introspection.Kernel.report_activity(state.root_agent_id, :idle)

    if state.turn_start_ms do
      Telemetry.emit_conversation_turn_stop(state.session_id, state.turn_start_ms, %{
        prompt_tokens: normalized_usage.prompt_tokens,
        completion_tokens: normalized_usage.completion_tokens
      })
    end

    new_state = %{
      state
      | history: SessionHistory.prune(final_history, state.session_id),
        status: :idle,
        worker_pid: nil,
        worker_ref: nil,
        token_usage_total: new_totals,
        turn_start_ms: nil
    }

    save_preferences(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({ref, {:error, reason}}, %{worker_ref: ref} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    handle_executor_failure(reason, state)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worker_ref: ref} = state)
      when is_reference(ref) do
    handle_executor_failure(reason, state)
  end

  @impl true
  def handle_info({ref, {:reply, response, usage}}, state)
      when is_reference(ref) and is_map_key(state.pending_evals, ref) do
    Process.demonitor(ref, [:flush])
    SessionHistory.persist_assistant_response(state.session_id, response)

    normalized_usage = Usage.normalize(usage)
    new_totals = Usage.add(state.token_usage_total, normalized_usage)
    new_history = state.history ++ [%{"role" => "assistant", "content" => response}]

    new_state = %{
      state
      | history: new_history,
        token_usage_total: new_totals,
        pending_evals: Map.delete(state.pending_evals, ref)
    }

    save_preferences(new_state)
    publish(state.session_id, {:agent_response, response, usage})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({ref, :ignore}, state)
      when is_reference(ref) and is_map_key(state.pending_evals, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | pending_evals: Map.delete(state.pending_evals, ref)}}
  end

  @impl true
  def handle_info({ref, {:error, reason}}, state)
      when is_reference(ref) and is_map_key(state.pending_evals, ref) do
    Process.demonitor(ref, [:flush])

    Logger.error(
      "[SESSION] #{state.session_id} evaluate_blackboard_update failed: #{inspect(reason)}"
    )

    {:noreply, %{state | pending_evals: Map.delete(state.pending_evals, ref)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_reference(ref) and is_map_key(state.pending_evals, ref) do
    Logger.error(
      "[SESSION] #{state.session_id} evaluate_blackboard_update crashed: #{inspect(reason)}"
    )

    {:noreply, %{state | pending_evals: Map.delete(state.pending_evals, ref)}}
  end

  # --- Session Lifecycle & Scheduling ---

  @impl true
  def handle_info(:recovery_catch_up, state) do
    Logger.info("[SESSION] #{state.session_id} Maestro performing recovery catch-up...")

    parent = self()
    since_id = state.last_blackboard_id
    scope = state.blackboard_scope

    Task.Supervisor.start_child(@task_supervisor, fn ->
      case Blackboard.fetch_new(since_id, scope: scope) do
        {[], _} -> :ok
        {messages, new_last_id} -> send(parent, {:recovery_catch_up_done, messages, new_last_id})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:recovery_catch_up_done, messages, new_last_id}, state) do
    Logger.info(
      "[SESSION] #{state.session_id} Caught up with #{length(messages)} missed messages."
    )

    process_blackboard_messages(messages, new_last_id, state, broadcast?: false)
  end

  @impl true
  def handle_info(:trigger_bootstrap, state) do
    history_with_prompt = [%{"role" => "system", "content" => system_prompt(state)}]
    {:noreply, start_unsolicited_eval(state, history_with_prompt, :bootstrap)}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, 10_000)

    case Blackboard.fetch_new(state.last_blackboard_id, scope: state.blackboard_scope) do
      {[], _} ->
        {:noreply, state}

      {messages, new_last_id} ->
        process_blackboard_messages(messages, new_last_id, state, broadcast?: true)
    end
  end

  @impl true
  def handle_info({:system_update_prompt}, state) do
    Logger.info("[SESSION] #{state.session_id} hot-swapping system prompt...")
    new_history = SessionHistory.swap_system_prompt(state.history, system_prompt(state))
    {:noreply, %{state | history: new_history}}
  end

  @impl true
  def handle_info(:flush_input, state) do
    combined_input =
      state.input_buffer
      |> Enum.map_join("\n", &SessionHistory.content_to_text/1)

    state = %{state | input_buffer: [], debounce_timer: nil}

    case ProjectRouter.parse(combined_input) do
      {:ok, cmd, args} ->
        session_id = state.session_id

        Task.Supervisor.start_child(@task_supervisor, fn ->
          case ProjectRouter.handle_command(cmd, args, session_id) do
            {:ok, id} ->
              publish(session_id, {:agent_response, "🚀 Project started with ID: `#{id}`"})

            _ ->
              publish(session_id, {:agent_response, "✅ Command #{cmd} executed."})
          end
        end)

        {:noreply, state}

      :error ->
        {:reply, _reply, new_state} = process_standard_input(combined_input, state)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:cron_trigger, prompt}, state) when is_binary(prompt) do
    Logger.info("[SESSION] #{state.session_id} cron trigger: #{String.slice(prompt, 0, 80)}")
    {:reply, _, new_state} = process_standard_input(prompt, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:scheduler_trigger, prompt}, state) when is_binary(prompt) do
    Logger.info("[SESSION] #{state.session_id} scheduler trigger: #{String.slice(prompt, 0, 80)}")
    {:reply, _, new_state} = process_standard_input(prompt, state)
    {:noreply, new_state}
  end

  # --- Runtime Forwarding & Telemetry ---

  @impl true
  def handle_info({:executor_trace, trace_meta}, state) when is_map(trace_meta) do
    Introspection.Kernel.report_trace(state.root_agent_id, trace_meta)
    maybe_update_lesson_outcomes(state.injected_lesson_ids, trace_meta)
    {:noreply, %{state | last_executor_trace: trace_meta, injected_lesson_ids: []}}
  end

  @impl true
  def handle_info({:agent_stream_token, token}, state) do
    publish(state.session_id, {:agent_partial, token})
    {:noreply, state}
  end

  @impl true
  def handle_info({:executor_status, status}, state) do
    publish(state.session_id, {:agent_status, status})
    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_runtime_status, %{kind: :failover} = meta}, state) do
    if state.verbose do
      msg = "🔄 **Failover**: Swapping to `#{meta.provider}/#{meta.model}` due to `#{meta.reason}`"
      publish(state.session_id, {:agent_response, msg})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_runtime_status, _meta}, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_partial, _token}, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_status, _status}, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_response, _content, _usage}, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_response, _content}, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_file, _path, _opts}, state), do: {:noreply, state}

  @impl true
  def handle_info({:sme_status, _sme_name, msg}, state) do
    publish(state.session_id, {:agent_status, msg})
    {:noreply, state}
  end

  @impl true
  def handle_info({:sme_tool_use, tools}, state) when is_list(tools) do
    joined = Enum.join(tools, "\n")
    publish(state.session_id, {:agent_status, "🛠️ Usando ferramentas:\n#{joined}"})
    {:noreply, state}
  end

  @impl true
  def handle_info({:sme_tool_use, tools}, state) do
    publish(state.session_id, {:agent_status, "🛠️ Usando ferramentas: #{tools}"})
    {:noreply, state}
  end

  @impl true
  def handle_info({:approval_required, call_id, command}, state) do
    Logger.info("[SESSION] #{state.session_id} Approval required for #{call_id}: #{command}")

    case SessionApproval.handle_request(call_id, command, state.auto_approve_until) do
      {:auto_approved, approved_call_id} ->
        Logger.info("[SESSION] #{state.session_id} Auto-approved: #{command}")
        send_approval_decision(state, approved_call_id, :approved)
        {:noreply, state}

      {:pending, pending} ->
        publish(state.session_id, {:approval_ui, call_id, command})
        {:noreply, %{state | pending_approval: pending}}
    end
  end

  @impl true
  def handle_info({:kernel_self_state_updated, self_state}, state) do
    {:noreply, %{state | self_state: self_state}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[SESSION] #{state.session_id} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- GenServer Call Handlers ---

  @impl true
  def handle_call(:get_status, _from, state), do: {:reply, {:ok, state}, state}

  @impl true
  def handle_call(:reset, _from, state) do
    Logger.info("[SESSION] #{state.session_id} resetting history...")

    history = state.history
    session_id = state.session_id

    Task.Supervisor.start_child(@task_supervisor, fn ->
      SessionHistory.record_reset_snapshot(session_id, history)
    end)

    state = state |> stop_worker() |> clear_pending_evals()
    Storage.delete_messages(state.session_id)
    new_history = [%{"role" => "system", "content" => system_prompt(state)}]

    if PromptAssembly.bootstrap_active?(state.workspace_path) do
      send(self(), :trigger_bootstrap)
    end

    {:reply, :ok, %{state | history: new_history, status: :idle, turn_start_ms: nil}}
  end

  @impl true
  def handle_call({:set_model, provider, model}, _from, state) do
    Logger.info("[SESSION] #{state.session_id} switching model to #{provider}:#{model}")

    if worker_alive?(state) do
      send(state.worker_pid, {:model_changed, provider, model})
    end

    new_state = %{state | model_override: %{provider: provider, model: model}}
    save_preferences(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_thinking, level}, _from, state) do
    new_state = %{state | thinking_level: level}
    save_preferences(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_reasoning_visible, visible}, _from, state) do
    new_state = %{state | reasoning_visible: visible}
    save_preferences(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_verbose, verbose}, _from, state) do
    {:reply, :ok, %{state | verbose: verbose}}
  end

  @impl true
  def handle_call({:set_usage, level}, _from, state) do
    new_state = %{state | usage_display: level}
    save_preferences(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:approve_all, seconds}, _from, state) do
    {until, pending_approval, effect} =
      SessionApproval.enable_auto_approve(state.pending_approval, seconds)

    Logger.info("[SESSION] #{state.session_id} Auto-approve enabled until #{until}")

    case effect do
      {:auto_approve, call_id} ->
        Logger.info("[SESSION] #{state.session_id} Auto-approved pending: #{call_id}")
        send_approval_decision(state, call_id, :approved)

      :noop ->
        :ok
    end

    {:reply, :ok, %{state | auto_approve_until: until, pending_approval: pending_approval}}
  end

  @impl true
  def handle_call({:process_input, %IncomingMessage{} = input}, _from, state) do
    text = SessionHistory.content_to_text(input)

    case state.pending_approval do
      nil ->
        handle_standard_process_input(input, text, state)

      pending ->
        case SessionApproval.resolve_pending(pending, text) do
          {:decided, call_id, decision} ->
            send_approval_decision(state, call_id, decision)
            {:reply, {:ok, :approval_sent}, %{state | pending_approval: nil}}

          {:prompt_again, ^pending} ->
            publish(
              state.session_id,
              {:agent_status, "⚠️ Aprovação pendente. Responda **Aprovo** ou **Rejeito**."}
            )

            {:reply, {:ok, :buffered}, state}
        end
    end
  end

  def handle_call({:process_input, input}, from, state) when is_binary(input) do
    msg = IncomingMessage.new(state.session_id, input)
    handle_call({:process_input, msg}, from, state)
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[SERVER] Session #{state.session_id} terminating: #{inspect(reason)}")
    _ = state |> stop_worker() |> clear_pending_evals()
    Archivist.start_consolidation(state.session_id, [], workspace_path: state.workspace_path)
    :ok
  end

  # --- Internal Helpers ---

  defp process_blackboard_messages(messages, new_last_id, state, opts) do
    broadcast? = Keyword.get(opts, :broadcast?, true)

    %{
      history: new_history,
      tracker: tracker,
      notifications: notifications,
      needs_review?: review?
    } =
      SessionBlackboard.ingest(state.history, state.subagent_progress_tracker, messages)

    if broadcast? do
      Enum.each(notifications, &publish(state.session_id, {:agent_status, &1}))
    end

    next_state = %{
      state
      | history: new_history,
        last_blackboard_id: new_last_id,
        subagent_progress_tracker: tracker
    }

    if broadcast? and state.status == :idle and review? do
      {:noreply, start_unsolicited_eval(next_state, new_history, :blackboard)}
    else
      {:noreply, next_state}
    end
  end

  defp handle_standard_process_input(input, text, state) do
    if SessionApproval.cancel_command?(text) do
      if worker_alive?(state) do
        new_state = stop_worker(state)
        publish(state.session_id, {:agent_response, "🛑 Execução cancelada pelo usuário."})
        if state.debounce_timer, do: Process.cancel_timer(state.debounce_timer)

        {:reply, {:ok, :stopped},
         %{new_state | status: :idle, input_buffer: [], debounce_timer: nil, turn_start_ms: nil}}
      else
        {:reply, {:ok, :idle}, state}
      end
    else
      if state.status == :working do
        publish(
          state.session_id,
          {:agent_status, "⏳ Mensagem recebida. Vou processar após concluir o passo atual..."}
        )
      end

      if state.debounce_timer, do: Process.cancel_timer(state.debounce_timer)
      new_buffer = state.input_buffer ++ [input.text]
      new_timer = Process.send_after(self(), :flush_input, 1200)

      {:reply, {:ok, :buffered}, %{state | input_buffer: new_buffer, debounce_timer: new_timer}}
    end
  end

  defp process_standard_input(input, state) do
    SessionHistory.persist_user_input(state.session_id, input, state.workspace_path)
    user_msg = SessionHistory.build_user_message(input, state.workspace_path)
    new_history = state.history ++ [user_msg]

    executor_opts =
      [
        model_override: model_override_with_thinking(state),
        workspace_path: state.workspace_path,
        trace_events?: true,
        notify?: false
      ]
      |> maybe_put_opt(:llm_client, state.llm_client)

    turn_start_ms = Telemetry.emit_conversation_turn_start(state.session_id)
    parent = self()

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        Executor.run(parent, state.session_id, new_history, executor_opts)
      end)

    lesson_ids = Introspection.Kernel.get_lesson_ids(state.root_agent_id)
    Introspection.Kernel.report_activity(state.root_agent_id, :working)

    {:reply, {:ok, :started},
     %{
       state
       | history: new_history,
         worker_pid: task.pid,
         worker_ref: task.ref,
         status: :working,
         injected_lesson_ids: lesson_ids,
         turn_start_ms: turn_start_ms
     }}
  end

  defp start_unsolicited_eval(state, history, kind) do
    eval_opts = maybe_put_opt([], :llm_client, state.llm_client)
    model_override = state.model_override

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        SessionBlackboard.evaluate_update(history, model_override, eval_opts)
      end)

    %{state | pending_evals: Map.put(state.pending_evals, task.ref, kind)}
  end

  defp handle_executor_failure(reason, state) do
    Logger.error("[SESSION] #{state.session_id} Executor failed: #{inspect(reason)}")
    Telemetry.emit_conversation_error(state.session_id, reason)
    Introspection.Kernel.report_activity(state.root_agent_id, :idle)

    error_msg = "❌ #{ErrorUX.friendly(reason, scope: :executor)}"
    publish(state.session_id, {:agent_response, error_msg})

    {:noreply, %{state | status: :idle, worker_pid: nil, worker_ref: nil, turn_start_ms: nil}}
  end

  defp stop_worker(state) do
    if is_reference(state.worker_ref) do
      Process.demonitor(state.worker_ref, [:flush])
    end

    if worker_alive?(state) do
      case Task.Supervisor.terminate_child(@task_supervisor, state.worker_pid) do
        :ok -> :ok
        {:error, :not_found} -> Process.exit(state.worker_pid, :kill)
      end
    end

    %{state | worker_pid: nil, worker_ref: nil}
  end

  defp clear_pending_evals(state) do
    Enum.each(state.pending_evals, fn {ref, _kind} ->
      if is_reference(ref), do: Process.demonitor(ref, [:flush])
    end)

    %{state | pending_evals: %{}}
  end

  defp send_approval_decision(state, call_id, decision) do
    if worker_alive?(state) do
      send(state.worker_pid, {:tool_approval_result, call_id, decision})
    end
  end

  defp worker_alive?(%{worker_pid: pid}) when is_pid(pid), do: Process.alive?(pid)
  defp worker_alive?(_state), do: false

  defp system_prompt(state) do
    PromptAssembly.build_system_prompt(
      workspace_path: state.workspace_path,
      root_agent_id: state.root_agent_id,
      self_state: state.self_state
    )
  end

  defp model_override_with_thinking(%{thinking_level: level, model_override: override})
       when not is_nil(level) and is_map(override) do
    Map.put(override, :thinking_level, level)
  end

  defp model_override_with_thinking(%{model_override: override}), do: override

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp publish(session_id, event), do: PubSub.broadcast("session:#{session_id}", event)

  defp maybe_start_graph_watcher(workspace_path) do
    if Application.get_env(:pincer, :enable_graph_watcher, true) do
      case Pincer.Core.Graph.Watcher.start_link(workspace_root: workspace_path) do
        {:ok, pid} -> pid
        _ -> nil
      end
    end
  end

  defp save_preferences(%{workspace_path: nil, session_id: session_id}) do
    Logger.warning("[SESSION] #{session_id} save_preferences skipped: workspace_path is nil")
  end

  defp save_preferences(state) do
    result =
      Preferences.save(state.workspace_path, %{
        model_override: state.model_override,
        thinking_level: state.thinking_level,
        reasoning_visible: state.reasoning_visible,
        usage_display: state.usage_display,
        token_usage_total: state.token_usage_total
      })

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[SESSION] #{state.session_id} save_preferences failed (workspace=#{state.workspace_path}): #{inspect(reason)}"
        )
    end
  end

  defp verify_alignment_integrity(workspace_path, session_id) do
    case AlignmentIntegrity.verify(workspace_path) do
      {:ok, []} ->
        :ok

      {:ok, violations} ->
        files = Enum.map_join(violations, ", ", & &1.file)
        Logger.warning("[SESSION] #{session_id} alignment integrity violation: #{files}")

      {:error, :no_snapshot} ->
        if AlignmentIntegrity.protected_files(workspace_path) != [] do
          AlignmentIntegrity.snapshot!(workspace_path)
          Logger.info("[SESSION] #{session_id} alignment integrity snapshot created")
        end
    end
  end

  defp maybe_update_lesson_outcomes([], _trace_meta), do: :ok

  defp maybe_update_lesson_outcomes(lesson_ids, trace_meta) do
    outcome = trace_outcome(trace_meta)

    Task.Supervisor.start_child(@task_supervisor, fn ->
      Enum.each(lesson_ids, fn id ->
        Introspection.LessonStore.record_outcome(id, outcome)
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

  defp via_tuple(id), do: CoreRegistry.via_tuple(Pincer.Core.Session.Registry, id, :local)
end
