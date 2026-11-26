defmodule Pincer.Core.Session.Server do
  @moduledoc """
  Core session GenServer implementing the Pincer Brain (The Maestro).

  The Maestro owns the GenServer lifecycle, local/Horde registration, and
  conversation state orchestration while delegating task supervision to
  `TaskCoordinator`, Blackboard polling/ingestion to `BlackboardIngestor`,
  debounced input queuing to `InputBuffer`, and control/approval commands to
  `CommandDispatcher`.
  """
  use GenServer, restart: :transient
  require Logger

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Executor.PromptAssembly
  alias Pincer.Core.Introspection
  alias Pincer.Core.Orchestration.Archivist
  alias Pincer.Core.Registry, as: CoreRegistry
  alias Pincer.Core.Session.AlignmentIntegrity
  alias Pincer.Core.Session.BlackboardIngestor
  alias Pincer.Core.Session.CommandDispatcher
  alias Pincer.Core.Session.History, as: SessionHistory
  alias Pincer.Core.Session.InputBuffer
  alias Pincer.Core.Session.Preferences
  alias Pincer.Core.Session.TaskCoordinator
  alias Pincer.Core.Telemetry
  alias Pincer.Infra.PubSub
  alias PincerPorts.Structs.IncomingMessage

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
    Introspection.Kernel.ensure_started(root_agent_id, workspace_path: workspace_path)
    Introspection.Kernel.register_session(root_agent_id, self())
    self_state = Introspection.Kernel.get_self_state(root_agent_id)

    AlignmentIntegrity.ensure_verified(workspace_path, session_id)
    PubSub.subscribe("session:#{session_id}")
    PubSub.subscribe("system:updates")

    prefs = Preferences.load(workspace_path)

    if prefs.model_override do
      Logger.info(
        "[SESSION] #{session_id} loaded model preference: #{prefs.model_override.provider}:#{prefs.model_override.model}"
      )
    end

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
      watcher_pid: maybe_start_graph_watcher(workspace_path),
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

  @impl true
  def handle_info({ref, _} = msg, state) when is_reference(ref),
    do: dispatch_task_message(msg, state)

  def handle_info({:DOWN, ref, :process, _pid, _reason} = msg, state) when is_reference(ref),
    do: dispatch_task_message(msg, state)

  def handle_info(:recovery_catch_up, state) do
    Logger.info("[SESSION] #{state.session_id} Maestro performing recovery catch-up...")
    BlackboardIngestor.start_recovery_catch_up(state, self())
    {:noreply, state}
  end

  def handle_info({:recovery_catch_up_done, messages, new_last_id}, state) do
    Logger.info(
      "[SESSION] #{state.session_id} Caught up with #{length(messages)} missed messages."
    )

    {_status, next_state} =
      BlackboardIngestor.ingest_batch(messages, new_last_id, state, broadcast?: false)

    {:noreply, next_state}
  end

  def handle_info(:trigger_bootstrap, state) do
    history_with_prompt = [%{"role" => "system", "content" => system_prompt(state)}]
    {:noreply, TaskCoordinator.start_unsolicited_eval(state, history_with_prompt, :bootstrap)}
  end

  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, 10_000)

    case BlackboardIngestor.poll(state) do
      {:evaluate, next_state} ->
        {:noreply,
         TaskCoordinator.start_unsolicited_eval(next_state, next_state.history, :blackboard)}

      {_status, next_state} ->
        {:noreply, next_state}
    end
  end

  def handle_info({:system_update_prompt}, state) do
    Logger.info("[SESSION] #{state.session_id} hot-swapping system prompt...")
    new_history = SessionHistory.swap_system_prompt(state.history, system_prompt(state))
    {:noreply, %{state | history: new_history}}
  end

  def handle_info(:flush_input, state) do
    {combined_input, state} = InputBuffer.flush(state)

    case CommandDispatcher.dispatch_project_command(combined_input, state) do
      {:handled, next_state} -> {:noreply, next_state}
      :not_a_command -> {:noreply, TaskCoordinator.start_standard_turn(state, combined_input)}
    end
  end

  def handle_info({trigger, prompt}, state)
      when trigger in [:cron_trigger, :scheduler_trigger] and is_binary(prompt) do
    Logger.info("[SESSION] #{state.session_id} #{trigger}: #{String.slice(prompt, 0, 80)}")
    {:noreply, TaskCoordinator.start_standard_turn(state, prompt)}
  end

  def handle_info({:executor_trace, trace_meta}, state) when is_map(trace_meta),
    do: {:noreply, TaskCoordinator.record_trace(state, trace_meta)}

  def handle_info({:agent_stream_token, token}, state) do
    publish(state.session_id, {:agent_partial, token})
    {:noreply, state}
  end

  def handle_info({:executor_status, status}, state) do
    publish(state.session_id, {:agent_status, status})
    {:noreply, state}
  end

  def handle_info({:llm_runtime_status, %{kind: :failover} = meta}, state) do
    if state.verbose do
      msg = "🔄 **Failover**: Swapping to `#{meta.provider}/#{meta.model}` due to `#{meta.reason}`"
      publish(state.session_id, {:agent_response, msg})
    end

    {:noreply, state}
  end

  def handle_info({event, _}, state)
      when event in [:llm_runtime_status, :agent_partial, :agent_status, :agent_response],
      do: {:noreply, state}

  def handle_info({event, _, _}, state) when event in [:agent_response, :agent_file],
    do: {:noreply, state}

  def handle_info({:sme_status, _sme_name, msg}, state) do
    publish(state.session_id, {:agent_status, msg})
    {:noreply, state}
  end

  def handle_info({:sme_tool_use, tools}, state) when is_list(tools) do
    publish(state.session_id, {:agent_status, "🛠️ Usando ferramentas:\n#{Enum.join(tools, "\n")}"})
    {:noreply, state}
  end

  def handle_info({:sme_tool_use, tools}, state) do
    publish(state.session_id, {:agent_status, "🛠️ Usando ferramentas: #{tools}"})
    {:noreply, state}
  end

  def handle_info({:approval_required, call_id, command}, state),
    do: {:noreply, CommandDispatcher.handle_approval_required(call_id, command, state)}

  def handle_info({:kernel_self_state_updated, self_state}, state),
    do: {:noreply, %{state | self_state: self_state}}

  def handle_info({:kernel_skills_updated, _skill}, state) do
    new_history = SessionHistory.swap_system_prompt(state.history, system_prompt(state))
    {:noreply, %{state | history: new_history}}
  end

  def handle_info(msg, state) do
    Logger.debug("[SESSION] #{state.session_id} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- GenServer Call Handlers ---

  @impl true
  def handle_call(:get_status, _from, state), do: {:reply, {:ok, state}, state}

  def handle_call(:reset, _from, state),
    do: CommandDispatcher.dispatch_call(:reset, state, prompt_builder: &system_prompt/1)

  def handle_call({:set_model, _, _} = msg, _from, state),
    do: CommandDispatcher.dispatch_call(msg, state)

  def handle_call({cmd, _} = msg, _from, state)
      when cmd in [:set_thinking, :set_reasoning_visible, :set_verbose, :set_usage, :approve_all],
      do: CommandDispatcher.dispatch_call(msg, state)

  def handle_call({:process_input, %IncomingMessage{} = input}, _from, state) do
    text = SessionHistory.content_to_text(input)

    case state.pending_approval do
      nil ->
        if CommandDispatcher.cancel_command?(text) do
          CommandDispatcher.handle_cancel(state)
        else
          {:reply, {:ok, :buffered}, InputBuffer.enqueue(state, input.text)}
        end

      pending ->
        CommandDispatcher.handle_pending_approval_input(pending, text, state)
    end
  end

  def handle_call({:process_input, input}, from, state) when is_binary(input),
    do: handle_call({:process_input, IncomingMessage.new(state.session_id, input)}, from, state)

  @impl true
  def terminate(reason, state) do
    Logger.info("[SERVER] Session #{state.session_id} terminating: #{inspect(reason)}")
    _ = state |> TaskCoordinator.stop_worker() |> TaskCoordinator.clear_pending_evals()
    Archivist.start_consolidation(state.session_id, [], workspace_path: state.workspace_path)
    :ok
  end

  # --- Internal Helpers ---

  defp dispatch_task_message(msg, state) do
    case TaskCoordinator.handle_task_message(msg, state) do
      {:handled, new_state} ->
        {:noreply, new_state}

      :ignore ->
        Logger.debug("[SESSION] #{state.session_id} received unexpected message: #{inspect(msg)}")
        {:noreply, state}
    end
  end

  defp system_prompt(state) do
    PromptAssembly.build_system_prompt(
      workspace_path: state.workspace_path,
      root_agent_id: state.root_agent_id,
      self_state: state.self_state
    )
  end

  defp publish(session_id, event), do: PubSub.broadcast("session:#{session_id}", event)

  defp maybe_start_graph_watcher(workspace_path) do
    if Application.get_env(:pincer, :enable_graph_watcher, true) do
      case Pincer.Core.Graph.Watcher.start_link(workspace_root: workspace_path) do
        {:ok, pid} -> pid
        _ -> nil
      end
    end
  end

  defp via_tuple(id), do: CoreRegistry.via_tuple(Pincer.Core.Session.Registry, id, :local)
end
