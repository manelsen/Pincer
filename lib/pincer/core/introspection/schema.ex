defmodule Pincer.Core.Introspection.Schema do
  @moduledoc """
  Plain struct for agent introspective self-state.

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

  import Pincer.Utils.Validation

  @valid_wakefulness ~w(idle active reflecting)

  defstruct id: nil,
            agent_id: nil,
            wakefulness: "idle",
            focus: "",
            concerns: [],
            open_questions: [],
            work_lanes: [],
            last_reflection_summary: "",
            mood_valence: 0.0,
            mood_arousal: 0.0,
            meta: %{},
            inserted_at: nil,
            updated_at: nil

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

  @doc """
  Creates a changeset for validating and casting self-state attributes.
  """
  @spec changeset(t(), map()) :: Pincer.Utils.Validation.t()
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
  end
end
