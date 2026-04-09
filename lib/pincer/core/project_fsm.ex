defmodule Pincer.Core.ProjectFSM do
  @moduledoc """
  Explicit project lifecycle FSM with checkpoint persistence on transitions.
  """

  @type phase :: :objective | :scope | :plan | :execution | :review | :delivery

  @type state :: %{
          project_id: String.t(),
          session_id: String.t(),
          phase: phase(),
          objective: String.t() | nil,
          scope: String.t() | nil,
          plan: map() | nil,
          execution: map() | nil,
          review: map() | nil,
          delivery: map() | nil
        }

  @spec new(String.t(), String.t()) :: state()
  def new(project_id, session_id) when is_binary(project_id) and is_binary(session_id) do
    %{
      project_id: project_id,
      session_id: session_id,
      phase: :objective,
      objective: nil,
      scope: nil,
      plan: nil,
      execution: nil,
      review: nil,
      delivery: nil
    }
  end

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

  defp enrich_state(_state, _phase, _attrs), do: {:error, :unsupported_phase}

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
