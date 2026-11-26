defmodule Pincer.Core.ProjectFSM do
  @moduledoc """
  Explicit project lifecycle FSM with checkpoint persistence on transitions.

  Drives both the high-level lifecycle phases (`:objective` -> `:scope` ->
  `:plan` -> `:execution` -> `:review` -> `:delivery`) and the derived wizard
  collection phases (`:await_objective`, `:await_kind`, `:await_scope`,
  `:await_success`, `:ready`) so callers never maintain a separate phase field.
  """

  @type phase :: :objective | :scope | :plan | :execution | :review | :delivery
  @type wizard_phase :: :await_objective | :await_kind | :await_scope | :await_success | :ready
  @type project_kind :: :software | :non_software

  @type state :: %{
          project_id: String.t(),
          session_id: String.t(),
          phase: phase(),
          objective: String.t() | nil,
          kind: project_kind() | nil,
          scope: String.t() | nil,
          success_criteria: String.t() | nil,
          plan: map() | nil,
          execution: map() | nil,
          review: map() | nil,
          delivery: map() | nil
        }

  @doc "Creates a new FSM state in the initial `:objective` phase."
  @spec new(String.t(), String.t()) :: state()
  def new(project_id, session_id) when is_binary(project_id) and is_binary(session_id) do
    %{
      project_id: project_id,
      session_id: session_id,
      phase: :objective,
      objective: nil,
      kind: nil,
      scope: nil,
      success_criteria: nil,
      plan: nil,
      execution: nil,
      review: nil,
      delivery: nil
    }
  end

  @doc "Derives the wizard collection/ready phase from an FSM state."
  @spec wizard_phase(state() | map() | nil) :: wizard_phase() | :unknown
  def wizard_phase(%{phase: :objective}), do: :await_objective

  def wizard_phase(%{phase: :scope} = state) do
    if is_nil(Map.get(state, :kind)), do: :await_kind, else: :await_scope
  end

  def wizard_phase(%{phase: :plan} = state) do
    if is_nil(Map.get(state, :plan)), do: :await_success, else: :ready
  end

  def wizard_phase(%{phase: phase}) when phase in [:execution, :review, :delivery], do: :ready
  def wizard_phase(_), do: :unknown

  @doc "Records the project kind while in the `:scope` collection phase."
  @spec set_kind(state(), project_kind()) :: {:ok, state()} | {:error, {:invalid_kind, map()}}
  def set_kind(%{phase: :scope} = state, kind) when kind in [:software, :non_software] do
    {:ok, Map.put(state, :kind, kind)}
  end

  def set_kind(state, kind) when is_map(state) do
    {:error, {:invalid_kind, %{phase: Map.get(state, :phase), kind: kind}}}
  end

  @doc "Attaches finalized success criteria and plan metadata while in `:plan`."
  @spec attach_plan(state(), String.t(), map()) ::
          {:ok, state()} | {:error, {:invalid_plan, map()}}
  def attach_plan(%{phase: :plan} = state, success_criteria, plan)
      when is_binary(success_criteria) and is_map(plan) and map_size(plan) > 0 do
    case String.trim(success_criteria) do
      "" ->
        {:error, {:invalid_plan, %{phase: :plan, reason: :success_criteria_required}}}

      _ ->
        {:ok, state |> Map.put(:success_criteria, success_criteria) |> Map.put(:plan, plan)}
    end
  end

  def attach_plan(state, _success_criteria, _plan) when is_map(state) do
    {:error, {:invalid_plan, %{phase: Map.get(state, :phase), reason: :invalid_phase_or_plan}}}
  end

  @doc "Transitions the FSM to an adjacent lifecycle phase and persists a checkpoint."
  @spec transition(state(), phase(), map(), keyword()) ::
          {:ok, state()} | {:error, {:invalid_transition, map()}}
  def transition(state, to_phase, attrs \\ %{}, opts \\ [])
      when is_map(state) and is_atom(to_phase) and is_map(attrs) and is_list(opts) do
    from_phase = Map.fetch!(state, :phase)
    storage = Keyword.get(opts, :storage, Pincer.Ports.Storage)

    with :ok <- validate_transition(from_phase, to_phase),
         {:ok, enriched} <- enrich_state(state, to_phase, attrs),
         {:ok, persisted} <- persist_checkpoint(enriched, from_phase, to_phase, storage) do
      {:ok, persisted}
    else
      {:error, {:invalid_transition, _} = invalid} ->
        {:error, invalid}

      {:error, reason} ->
        {:error, {:invalid_transition, %{from: from_phase, to: to_phase, reason: reason}}}
    end
  end

  defp validate_transition(:objective, :scope), do: :ok
  defp validate_transition(:scope, :plan), do: :ok
  defp validate_transition(:plan, :execution), do: :ok
  defp validate_transition(:execution, :review), do: :ok
  defp validate_transition(:review, :delivery), do: :ok

  defp validate_transition(from, to) do
    {:error, {:invalid_transition, %{from: from, to: to, reason: :non_adjacent_transition}}}
  end

  defp enrich_state(state, :scope, attrs) do
    objective = Map.get(attrs, :objective) || Map.get(state, :objective)
    enrich_with_text(state, :scope, :objective, objective, :objective_required)
  end

  defp enrich_state(state, :plan, attrs) do
    scope = Map.get(attrs, :scope) || Map.get(state, :scope)
    enrich_with_text(state, :plan, :scope, scope, :scope_required)
  end

  defp enrich_state(state, :execution, attrs) do
    case Map.get(attrs, :plan) || Map.get(state, :plan) do
      plan when is_map(plan) and map_size(plan) > 0 ->
        {:ok, %{state | phase: :execution, plan: plan}}

      _ ->
        {:error, :plan_required}
    end
  end

  defp enrich_state(state, :review, attrs) do
    case Map.get(attrs, :execution) || Map.get(state, :execution) do
      execution when is_map(execution) and map_size(execution) > 0 ->
        {:ok, %{state | phase: :review, execution: execution}}

      _ ->
        {:error, :execution_required}
    end
  end

  defp enrich_state(state, :delivery, attrs) do
    delivery = Map.get(attrs, :delivery) || Map.get(state, :delivery) || %{}

    case Map.get(attrs, :review) || Map.get(state, :review) do
      review when is_map(review) and map_size(review) > 0 ->
        {:ok, %{state | phase: :delivery, review: review, delivery: delivery}}

      _ ->
        {:error, :review_required}
    end
  end

  defp enrich_with_text(state, phase, field, value, error_tag) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error_tag}
      _ -> {:ok, state |> Map.put(:phase, phase) |> Map.put(field, value)}
    end
  end

  defp enrich_with_text(_state, _phase, _field, _value, error_tag),
    do: {:error, error_tag}

  defp persist_checkpoint(state, from_phase, to_phase, storage) do
    checkpoint = %{
      status: "running",
      phase: Atom.to_string(to_phase),
      project_id: state.project_id,
      metadata: %{
        fsm_transition: %{
          from: Atom.to_string(from_phase),
          to: Atom.to_string(to_phase)
        }
      }
    }

    case storage.save_checkpoint(state.session_id, checkpoint) do
      {:ok, _record} -> {:ok, state}
      :ok -> {:ok, state}
      {:error, reason} -> {:error, {:checkpoint_persist_failed, reason}}
      other -> {:error, {:checkpoint_persist_failed, other}}
    end
  end
end
