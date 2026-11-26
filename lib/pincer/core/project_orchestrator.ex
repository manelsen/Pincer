defmodule Pincer.Core.ProjectOrchestrator do
  @moduledoc """
  Session-scoped project orchestration coordinator used by `/project` and `/kanban`.

  Delegates wizard prompts/steps to `Pincer.Core.Project.Wizard`, plan & task
  transitions to `Pincer.Core.Project.Plan`, board/markdown rendering to
  `Pincer.Core.Project.Renderer`, and ETS + durable persistence to
  `Pincer.Core.Project.Store`, while driving all lifecycle transitions through
  the single authoritative `Pincer.Core.ProjectFSM`.
  """

  require Logger

  alias Pincer.Core.Project.{Plan, Renderer, Store, Wizard}
  alias Pincer.Core.ProjectFSM

  @type phase :: Wizard.wizard_phase()
  @type project_kind :: Wizard.project_kind()
  @type item_status :: Plan.item_status()
  @type item :: Plan.item()

  @type state :: %{
          session_id: String.t(),
          project_id: String.t(),
          fsm_state: ProjectFSM.state(),
          objective: String.t() | nil,
          kind: project_kind() | nil,
          scope: String.t() | nil,
          success_criteria: String.t() | nil,
          items: [item()],
          retry_count: non_neg_integer(),
          retry_limit: non_neg_integer(),
          git_branch: String.t() | nil,
          git_branch_status: :created | :existing | {:error, any()} | nil
        }

  defmodule NoopFSMStorage do
    @moduledoc false
    def save_checkpoint(_session_id, _checkpoint), do: :ok
  end

  @doc """
  Starts (or resumes) the project wizard for a session.

  Optional `seed_input` can be used to immediately answer the current step.
  """
  @spec start(String.t(), String.t() | nil) :: String.t()
  def start(session_id, seed_input \\ nil) when is_binary(session_id) do
    Store.ensure_orchestrator_table()

    case Wizard.normalize_text(seed_input) do
      "reset" ->
        reset(session_id)
        session_id |> get_or_create_state() |> Wizard.prompt()

      seed when seed in [nil, ""] ->
        session_id |> get_or_create_state() |> Wizard.prompt()

      seed ->
        session_id |> get_or_create_state() |> advance(seed)
    end
  end

  @doc """
  Continues wizard collection from free-form user messages.

  Returns `:not_active` when the session is not in an active wizard phase.
  """
  @spec continue(String.t(), String.t()) :: {:handled, String.t()} | :not_active
  def continue(session_id, user_message) when is_binary(session_id) and is_binary(user_message) do
    case Store.get_orchestrator_state(session_id) do
      nil ->
        :not_active

      state ->
        if Wizard.collecting?(state),
          do: {:handled, advance(state, user_message)},
          else: :not_active
    end
  end

  @doc "Returns `true` when the project wizard is currently collecting information."
  @spec collecting?(String.t()) :: boolean()
  def collecting?(session_id) when is_binary(session_id) do
    case Store.get_orchestrator_state(session_id) do
      nil -> false
      state -> Wizard.collecting?(state)
    end
  end

  @doc "Returns current collection/plan phase derived from `fsm_state`."
  @spec phase(String.t()) :: phase() | :unknown
  def phase(session_id) when is_binary(session_id) do
    case Store.get_orchestrator_state(session_id) do
      %{fsm_state: fsm_state} -> ProjectFSM.wizard_phase(fsm_state)
      _ -> :unknown
    end
  end

  @doc "Renders a kanban board from the session project state when available."
  @spec board(String.t(), keyword()) :: {:ok, String.t()} | :not_found
  def board(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    case Store.get_orchestrator_state(session_id) do
      %{fsm_state: fsm_state} = state ->
        if ProjectFSM.wizard_phase(fsm_state) == :ready,
          do: {:ok, Renderer.render_board(state, opts)},
          else: :not_found

      _ ->
        :not_found
    end
  end

  @doc "Starts (or resumes) project task execution for the current session plan."
  @spec kickoff(String.t()) :: :not_ready | :already_started | :completed | {:ok, map()}
  def kickoff(session_id) when is_binary(session_id) do
    with %{} = state <- Store.get_orchestrator_state(session_id),
         {:ok, fsm_ready_state} <- ensure_execution_fsm(state),
         {:started, next_state, task} <- Plan.start_next_task(fsm_ready_state) do
      Store.put_orchestrator_state(next_state)
      {:ok, Renderer.task_progress(:started, next_state, %{task: task})}
    else
      nil -> :not_ready
      {:error, _reason} -> :not_ready
      other -> other
    end
  end

  @doc "Marks execution progress after a successful agent response."
  @spec on_agent_response(String.t()) :: :noop | {:next, map()} | {:completed, map()}
  def on_agent_response(session_id) when is_binary(session_id) do
    with %{} = state <- Store.get_orchestrator_state(session_id) do
      case Plan.complete_current_task(state) do
        {:next, next_state, completed_task, next_task} ->
          Store.put_orchestrator_state(next_state)

          {:next,
           Renderer.task_progress(:next, next_state, %{completed: completed_task, task: next_task})}

        {:all_done, finished_state, completed_task} ->
          complete_fsm_delivery(finished_state, completed_task)

        :noop ->
          :noop
      end
    else
      nil -> :noop
    end
  end

  @doc "Applies retry policy when an agent task fails."
  @spec on_agent_error(String.t()) :: :noop | {:retry, map()} | {:paused, map()}
  def on_agent_error(session_id) when is_binary(session_id) do
    with %{} = state <- Store.get_orchestrator_state(session_id) do
      case Plan.fail_current_task(state) do
        {:retry, updated, task, next_retry} ->
          Store.put_orchestrator_state(updated)
          {:retry, Renderer.task_progress(:retry, updated, %{task: task, attempt: next_retry})}

        {:paused, paused, task} ->
          Store.put_orchestrator_state(paused)
          {:paused, Renderer.task_progress(:paused, paused, %{task: task})}

        :noop ->
          :noop
      end
    else
      nil -> :noop
    end
  end

  @doc "Clears project orchestration state for a single session."
  @spec reset(String.t()) :: :ok
  def reset(session_id) when is_binary(session_id),
    do: Store.delete_orchestrator_state(session_id)

  @doc false
  @spec reset_all() :: :ok
  def reset_all, do: Store.reset_orchestrator_states()

  @doc false
  @spec list_projects(String.t()) :: [{String.t(), map()}]
  def list_projects(session_id) when is_binary(session_id) do
    case Store.get_orchestrator_state(session_id) do
      nil -> []
      state -> [{session_id, %{session_id: session_id, status: Store.orchestrator_status(state)}}]
    end
  end

  defp complete_fsm_delivery(finished_state, completed_task) do
    exec_attrs = %{
      execution: %{completed_task: completed_task, retries: finished_state.retry_count}
    }

    review_attrs = %{review: %{approved: true, completed_task: completed_task}}

    with {:ok, review_state} <- transition_fsm(finished_state, :review, exec_attrs),
         {:ok, completed_state} <- transition_fsm(review_state, :delivery, review_attrs) do
      Store.put_orchestrator_state(completed_state)

      {:completed,
       Renderer.task_progress(:completed, completed_state, %{completed: completed_task})}
    else
      {:error, _reason} -> :noop
    end
  end

  defp get_or_create_state(session_id) do
    Store.get_orchestrator_state(session_id) ||
      session_id |> new_state() |> Store.put_orchestrator_state()
  end

  defp new_state(session_id) do
    project_id = Store.build_project_id(session_id)

    %{
      session_id: session_id,
      project_id: project_id,
      fsm_state: ProjectFSM.new(project_id, session_id),
      objective: nil,
      kind: nil,
      scope: nil,
      success_criteria: nil,
      items: [],
      retry_count: 0,
      retry_limit: Plan.retry_limit(),
      git_branch: nil,
      git_branch_status: nil
    }
  end

  defp advance(state, input) do
    case Wizard.step(state, input) do
      {:transition, to_phase, attrs, prompt} ->
        apply_step(transition_fsm(state, to_phase, attrs), state, attrs, prompt)

      {:set_kind, kind, prompt} ->
        with {:ok, next_fsm} <- ProjectFSM.set_kind(state.fsm_state, kind) do
          %{state | fsm_state: next_fsm, kind: kind} |> Store.put_orchestrator_state()
          prompt
        else
          {:error, _reason} -> Wizard.prompt(state)
        end

      {:finalize_plan, success_criteria} ->
        {prepared, plan_payload} = Plan.prepare(state, success_criteria)

        with {:ok, next_fsm} <-
               ProjectFSM.attach_plan(prepared.fsm_state, success_criteria, plan_payload) do
          ready_state = %{prepared | fsm_state: next_fsm}
          Store.put_orchestrator_state(ready_state)
          Renderer.render_ready_message(ready_state)
        else
          {:error, _reason} -> Wizard.prompt(state)
        end

      {:noop, _state, prompt} ->
        prompt
    end
  end

  defp apply_step({:ok, next_state}, _prev, attrs, prompt) do
    next_state |> Map.merge(attrs) |> Store.put_orchestrator_state()
    prompt
  end

  defp apply_step({:error, _reason}, prev, _attrs, _prompt), do: Wizard.prompt(prev)

  defp ensure_execution_fsm(%{fsm_state: %{phase: :plan, plan: plan}} = state)
       when is_map(plan) and map_size(plan) > 0,
       do: transition_fsm(state, :execution, %{plan: plan})

  defp ensure_execution_fsm(state), do: {:ok, state}

  defp transition_fsm(%{fsm_state: fsm_state} = state, to_phase, attrs) do
    case ProjectFSM.transition(fsm_state, to_phase, attrs, storage: fsm_storage()) do
      {:ok, next_fsm} ->
        {:ok, %{state | fsm_state: next_fsm}}

      {:error, reason} ->
        Logger.debug("[PROJECT] FSM transition skipped: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fsm_storage, do: Application.get_env(:pincer, :project_fsm_storage, NoopFSMStorage)
end
