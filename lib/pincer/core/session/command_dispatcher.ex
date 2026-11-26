defmodule Pincer.Core.Session.CommandDispatcher do
  @moduledoc """
  Handles session control commands, preference updates, tool approval flows,
  cancellations, and `/project` command dispatch for `Pincer.Core.Session.Server`.
  """

  require Logger

  alias Pincer.Core.Executor.PromptAssembly
  alias Pincer.Core.Project.ProjectRouter
  alias Pincer.Core.Session.Approval, as: SessionApproval
  alias Pincer.Core.Session.History, as: SessionHistory
  alias Pincer.Core.Session.InputBuffer
  alias Pincer.Core.Session.Preferences
  alias Pincer.Core.Session.TaskCoordinator
  alias Pincer.Infra.PubSub
  alias Pincer.Ports.Storage

  @task_supervisor Pincer.Core.TaskSupervisor

  @doc """
  Executes synchronous session control calls (`:reset`, `{:set_model, ...}`,
  `{:set_thinking, ...}`, `{:set_reasoning_visible, ...}`, `{:set_verbose, ...}`,
  `{:set_usage, ...}`, `{:approve_all, ...}`) and returns `{:reply, :ok, new_state}`.
  """
  @spec dispatch_call(term(), map(), keyword()) :: {:reply, :ok, map()}
  def dispatch_call(command, state, opts \\ [])

  def dispatch_call(:reset, state, opts) do
    Logger.info("[SESSION] #{state.session_id} resetting history...")

    task_supervisor = Keyword.get(opts, :task_supervisor, @task_supervisor)
    storage = Keyword.get(opts, :storage, Storage)
    history_mod = Keyword.get(opts, :history_mod, SessionHistory)
    prompt_builder = Keyword.get(opts, :prompt_builder, &default_system_prompt/1)
    bootstrap_check = Keyword.get(opts, :bootstrap_check, &PromptAssembly.bootstrap_active?/1)
    self_pid = Keyword.get(opts, :self_pid, self())

    history = state.history
    session_id = state.session_id

    Task.Supervisor.start_child(task_supervisor, fn ->
      history_mod.record_reset_snapshot(session_id, history)
    end)

    state =
      state
      |> TaskCoordinator.stop_worker(opts)
      |> TaskCoordinator.clear_pending_evals()

    storage.delete_messages(state.session_id)
    new_history = [%{"role" => "system", "content" => prompt_builder.(state)}]

    if bootstrap_check.(state.workspace_path) do
      send(self_pid, :trigger_bootstrap)
    end

    {:reply, :ok, %{state | history: new_history, status: :idle, turn_start_ms: nil}}
  end

  def dispatch_call({:set_model, provider, model}, state, opts) do
    Logger.info("[SESSION] #{state.session_id} switching model to #{provider}:#{model}")
    TaskCoordinator.notify_model_changed(state, provider, model)
    new_state = %{state | model_override: %{provider: provider, model: model}}
    preferences_mod(opts).save_state(new_state)
    {:reply, :ok, new_state}
  end

  def dispatch_call({:set_thinking, level}, state, opts) do
    new_state = %{state | thinking_level: level}
    preferences_mod(opts).save_state(new_state)
    {:reply, :ok, new_state}
  end

  def dispatch_call({:set_reasoning_visible, visible}, state, opts) do
    new_state = %{state | reasoning_visible: visible}
    preferences_mod(opts).save_state(new_state)
    {:reply, :ok, new_state}
  end

  def dispatch_call({:set_verbose, verbose}, state, _opts) do
    {:reply, :ok, %{state | verbose: verbose}}
  end

  def dispatch_call({:set_usage, level}, state, opts) do
    new_state = %{state | usage_display: level}
    preferences_mod(opts).save_state(new_state)
    {:reply, :ok, new_state}
  end

  def dispatch_call({:approve_all, seconds}, state, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    {until, pending_approval, effect} =
      SessionApproval.enable_auto_approve(state.pending_approval, seconds, now)

    Logger.info("[SESSION] #{state.session_id} Auto-approve enabled until #{until}")

    case effect do
      {:auto_approve, call_id} ->
        Logger.info("[SESSION] #{state.session_id} Auto-approved pending: #{call_id}")
        TaskCoordinator.send_approval_decision(state, call_id, :approved)

      :noop ->
        :ok
    end

    {:reply, :ok, %{state | auto_approve_until: until, pending_approval: pending_approval}}
  end

  @doc """
  Processes an incoming `{:approval_required, call_id, command}` request,
  auto-approving if active or storing pending approval and publishing UI prompt.
  """
  @spec handle_approval_required(String.t(), String.t(), map(), keyword()) :: map()
  def handle_approval_required(call_id, command, state, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    publish_fn = publish_fn(opts)
    Logger.info("[SESSION] #{state.session_id} Approval required for #{call_id}: #{command}")

    case SessionApproval.handle_request(call_id, command, state.auto_approve_until, now) do
      {:auto_approved, approved_call_id} ->
        Logger.info("[SESSION] #{state.session_id} Auto-approved: #{command}")
        TaskCoordinator.send_approval_decision(state, approved_call_id, :approved)
        state

      {:pending, pending} ->
        publish_fn.(state.session_id, {:approval_ui, call_id, command})
        %{state | pending_approval: pending}
    end
  end

  @doc """
  Resolves user text against an active pending tool approval.
  """
  @spec handle_pending_approval_input({String.t(), String.t()}, String.t(), map(), keyword()) ::
          {:reply, {:ok, :approval_sent | :buffered}, map()}
  def handle_pending_approval_input(pending, text, state, opts \\ []) do
    publish_fn = publish_fn(opts)

    case SessionApproval.resolve_pending(pending, text) do
      {:decided, call_id, decision} ->
        TaskCoordinator.send_approval_decision(state, call_id, decision)
        {:reply, {:ok, :approval_sent}, %{state | pending_approval: nil}}

      {:prompt_again, ^pending} ->
        publish_fn.(
          state.session_id,
          {:agent_status, "⚠️ Aprovação pendente. Responda **Aprovo** ou **Rejeito**."}
        )

        {:reply, {:ok, :buffered}, state}
    end
  end

  @doc """
  Returns `true` when `text` is a user cancellation command.
  """
  @spec cancel_command?(String.t()) :: boolean()
  defdelegate cancel_command?(text), to: SessionApproval

  @doc """
  Stops an active worker turn and clears queued input when the user cancels.
  """
  @spec handle_cancel(map(), keyword()) :: {:reply, {:ok, :stopped | :idle}, map()}
  def handle_cancel(state, opts \\ []) do
    publish_fn = publish_fn(opts)

    if TaskCoordinator.worker_alive?(state) do
      new_state =
        state
        |> TaskCoordinator.stop_worker(opts)
        |> InputBuffer.clear(opts)

      publish_fn.(state.session_id, {:agent_response, "🛑 Execução cancelada pelo usuário."})
      {:reply, {:ok, :stopped}, %{new_state | status: :idle, turn_start_ms: nil}}
    else
      {:reply, {:ok, :idle}, state}
    end
  end

  @doc """
  Parses and asynchronously dispatches `/project` commands if `combined_input`
  matches a known project command, returning `{:handled, state}` or `:not_a_command`.
  """
  @spec dispatch_project_command(String.t(), map(), keyword()) ::
          {:handled, map()} | :not_a_command
  def dispatch_project_command(combined_input, state, opts \\ []) do
    project_router = Keyword.get(opts, :project_router, ProjectRouter)
    task_supervisor = Keyword.get(opts, :task_supervisor, @task_supervisor)
    publish_fn = publish_fn(opts)

    case project_router.parse(combined_input) do
      {:ok, cmd, args} ->
        session_id = state.session_id

        Task.Supervisor.start_child(task_supervisor, fn ->
          case project_router.handle_command(cmd, args, session_id) do
            {:ok, id} ->
              publish_fn.(session_id, {:agent_response, "🚀 Project started with ID: `#{id}`"})

            _ ->
              publish_fn.(session_id, {:agent_response, "✅ Command #{cmd} executed."})
          end
        end)

        {:handled, state}

      :error ->
        :not_a_command
    end
  end

  defp default_system_prompt(state) do
    PromptAssembly.build_system_prompt(
      workspace_path: state.workspace_path,
      root_agent_id: state.root_agent_id,
      self_state: state.self_state
    )
  end

  defp preferences_mod(opts), do: Keyword.get(opts, :preferences_mod, Preferences)

  defp publish_fn(opts) do
    Keyword.get(opts, :publish_fn, fn sid, event -> PubSub.broadcast("session:#{sid}", event) end)
  end
end
