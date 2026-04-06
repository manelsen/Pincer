defmodule Pincer.Core.Introspection.Schema do
  @moduledoc """
  Ecto schema for agent introspective self-state.

  Persists the agent's internal awareness — current focus, concerns,
  open questions, and reflection summaries — so that introspection
  survives restarts and can evolve across sessions.

  ## Wakefulness values

  | State | Meaning |
  |-------|---------|
  | `"idle"` | No active reflection cycle |
  | `"active"` | Agent is actively processing |
  | `"reflecting"` | Introspection cycle in progress |
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_wakefulness ~w(idle active reflecting)

  @type t :: %__MODULE__{
          id: binary() | nil,
          agent_id: String.t(),
          wakefulness: String.t(),
          focus: String.t(),
          concerns: [String.t()],
          open_questions: [String.t()],
          work_lanes: [map()],
          last_reflection_summary: String.t(),
          mood_valence: float(),
          mood_arousal: float(),
          meta: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]
  schema "self_states" do
    field(:agent_id, :string)
    field(:wakefulness, :string, default: "idle")
    field(:focus, :string, default: "")
    field(:concerns, {:array, :string}, default: [])
    field(:open_questions, {:array, :string}, default: [])
    field(:work_lanes, {:array, :map}, default: [])
    field(:last_reflection_summary, :string, default: "")
    field(:mood_valence, :float, default: 0.0)
    field(:mood_arousal, :float, default: 0.0)
    field(:meta, :map, default: %{})
    timestamps()
  end

  @doc """
  Creates a changeset for validating and casting self-state attributes.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(self_state, attrs) do
    self_state
    |> cast(attrs, [
      :agent_id,
      :wakefulness,
      :focus,
      :concerns,
      :open_questions,
      :work_lanes,
      :last_reflection_summary,
      :mood_valence,
      :mood_arousal,
      :meta
    ])
    |> validate_required([:agent_id])
    |> validate_inclusion(:wakefulness, @valid_wakefulness)
    |> unique_constraint(:agent_id)
  end
end
