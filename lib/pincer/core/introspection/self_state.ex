defmodule Pincer.Core.Introspection.SelfState do
  @moduledoc """
  Domain logic for agent introspective self-state.

  Provides loading, updating, and serialization of the agent's
  internal awareness. One `SelfState` row exists per agent,
  keyed by `agent_id`.
  """

  alias Pincer.Infra.Repo
  alias Pincer.Core.Introspection.Mood
  alias Pincer.Core.Introspection.Schema

  import Ecto.Query, only: [from: 2]

  @doc """
  Loads the self-state for the given agent, creating a default row
  if none exists.
  """
  @spec load_or_create(String.t()) :: {:ok, Schema.t()} | {:error, term()}
  def load_or_create(agent_id) do
    case Repo.one(from(s in Schema, where: s.agent_id == ^agent_id)) do
      %Schema{} = state ->
        {:ok, state}

      nil ->
        %Schema{}
        |> Schema.changeset(%{agent_id: agent_id})
        |> Repo.insert()
    end
  end

  @doc """
  Updates the self-state for the given agent.

  Only the provided keys in `attrs` are updated; other fields
  remain unchanged.
  """
  @spec update(String.t(), map()) :: {:ok, Schema.t()} | {:error, term()}
  def update(agent_id, attrs) do
    case Repo.one(from(s in Schema, where: s.agent_id == ^agent_id)) do
      nil ->
        {:error, :not_found}

      %Schema{} = state ->
        state
        |> Schema.changeset(Map.new(attrs))
        |> Repo.update()
    end
  end

  @doc """
  Serializes the self-state into a compact string suitable for
  injection into prompts (~200 tokens max).
  """
  @spec to_prompt_context(Schema.t()) :: String.t()
  def to_prompt_context(%Schema{} = s) do
    mood_label = Mood.label(s.mood_valence || 0.0, s.mood_arousal || 0.0)

    sections =
      [
        format_field("Wakefulness", s.wakefulness),
        format_field("Mood", mood_label),
        format_field("Focus", s.focus),
        format_list("Concerns", s.concerns),
        format_list("Open Questions", s.open_questions),
        format_field("Last Reflection", s.last_reflection_summary)
      ]
      |> Enum.reject(&(&1 == nil))

    Enum.join(sections, "\n")
  end

  defp format_field(_label, nil), do: nil
  defp format_field(_label, ""), do: nil
  defp format_field(label, value), do: "[#{label}] #{value}"

  defp format_list(_label, nil), do: nil
  defp format_list(_label, []), do: nil
  defp format_list(label, items), do: "[#{label}] #{Enum.join(items, "; ")}"
end
