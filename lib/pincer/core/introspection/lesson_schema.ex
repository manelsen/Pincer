defmodule Pincer.Core.Introspection.LessonSchema do
  @moduledoc """
  Plain struct for agent lessons (Self-Improving System).

  A lesson captures a reusable insight extracted from an execution
  episode or reflection cycle. Lessons carry a confidence score that
  is updated through a feedback loop: successful application increases
  confidence, contradictions penalize it.

  ## Confidence scoring factors

  | Factor | Weight | Description |
  |--------|--------|-------------|
  | Success rate | 40% | `success_count / (success_count + failure_count)` |
  | Recency | 25% | Exponential decay from `last_applied_at` (30-day half-life) |
  | Extraction confidence | 15% | LLM self-assessed at extraction time (stored in `extraction_confidence`) |
  | Contradiction penalty | 20% | Subtracted when lesson is contradicted; recovers 0.05 per success |

  ## Source values

  | Source | Meaning |
  |--------|---------|
  | `"reflection"` | Extracted from a reflection cycle |
  | `"episode"` | Extracted from an execution episode |
  | `"manual"` | Operator-provided |
  """

  import Pincer.Utils.Validation

  @valid_sources ~w(reflection episode manual)

  defstruct id: nil,
            agent_id: nil,
            content: nil,
            source: "reflection",
            confidence: 0.5,
            extraction_confidence: 0.5,
            success_count: 0,
            failure_count: 0,
            contradiction_penalty: 0.0,
            active: true,
            last_applied_at: nil,
            last_outcome: nil,
            meta: %{},
            inserted_at: nil,
            updated_at: nil

  @type t :: %__MODULE__{
          id: binary() | nil,
          agent_id: String.t(),
          content: String.t(),
          source: String.t(),
          confidence: float(),
          extraction_confidence: float(),
          success_count: non_neg_integer(),
          failure_count: non_neg_integer(),
          contradiction_penalty: float(),
          active: boolean(),
          last_applied_at: DateTime.t() | nil,
          last_outcome: String.t() | nil,
          meta: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Creates a changeset for validating and casting lesson attributes."
  @spec changeset(t(), map()) :: Pincer.Utils.Validation.t()
  def changeset(lesson, attrs) do
    lesson
    |> cast(attrs, [
      :agent_id,
      :content,
      :source,
      :confidence,
      :extraction_confidence,
      :success_count,
      :failure_count,
      :contradiction_penalty,
      :active,
      :last_applied_at,
      :last_outcome,
      :meta
    ])
    |> validate_required([:agent_id, :content])
    |> validate_inclusion(:source, @valid_sources)
    |> validate_number(:confidence,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
  end
end
