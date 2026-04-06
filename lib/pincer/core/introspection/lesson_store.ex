defmodule Pincer.Core.Introspection.LessonStore do
  @moduledoc """
  Domain logic for the Self-Improving System (SIS) lesson store.

  Manages lesson lifecycle: creation with novelty detection, confidence
  scoring, top-N retrieval for prompt injection, and outcome feedback.

  ## Confidence scoring

  Composite score from four weighted factors:

  | Factor | Weight | Range |
  |--------|--------|-------|
  | Success rate | 40% | 0.0–1.0 based on success_count / total |
  | Recency | 25% | Exponential decay, 30-day half-life |
  | Extraction confidence | 15% | LLM self-assessed at creation |
  | Contradiction penalty | 20% | Subtracted; recovers 0.05/success |

  ## Novelty detection

  Jaccard similarity on word sets. Lessons with >85% similarity to
  an existing lesson for the same agent are rejected as duplicates.
  """

  alias Pincer.Infra.Repo
  alias Pincer.Core.Introspection.LessonSchema

  import Ecto.Query

  @novelty_threshold 0.85
  @recency_half_life_days 30
  @penalty_recovery_per_success 0.05

  # --- Public API ---

  @doc """
  Creates a new lesson if sufficiently novel (Jaccard < #{@novelty_threshold}).
  Returns `{:error, :duplicate}` if too similar to an existing lesson.
  """
  @spec create(String.t(), map()) :: {:ok, LessonSchema.t()} | {:error, term()}
  def create(agent_id, attrs) do
    content = Map.get(attrs, :content, "")
    existing = list_active(agent_id)

    if duplicate?(content, existing) do
      {:error, :duplicate}
    else
      %LessonSchema{}
      |> LessonSchema.changeset(Map.put(attrs, :agent_id, agent_id))
      |> Repo.insert()
    end
  end

  @doc """
  Returns the top-N active lessons for an agent, ordered by confidence descending.

  ## Options
  - `:min_confidence` — minimum confidence threshold (default: 0.0)
  """
  @spec top_lessons(String.t(), non_neg_integer(), keyword()) :: [LessonSchema.t()]
  def top_lessons(agent_id, limit \\ 5, opts \\ []) do
    min_conf = Keyword.get(opts, :min_confidence, 0.0)

    from(l in LessonSchema,
      where: l.agent_id == ^agent_id and l.active == true and l.confidence >= ^min_conf,
      order_by: [desc: l.confidence],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Records a turn outcome for a lesson and recalculates confidence.
  """
  @spec record_outcome(binary(), :success | :failure) ::
          {:ok, LessonSchema.t()} | {:error, term()}
  def record_outcome(lesson_id, outcome) when outcome in [:success, :failure] do
    case Repo.get(LessonSchema, lesson_id) do
      nil ->
        {:error, :not_found}

      lesson ->
        updates =
          case outcome do
            :success ->
              penalty = max(0.0, lesson.contradiction_penalty - @penalty_recovery_per_success)

              %{
                success_count: lesson.success_count + 1,
                contradiction_penalty: penalty,
                last_outcome: "success",
                last_applied_at: DateTime.utc_now() |> DateTime.truncate(:second)
              }

            :failure ->
              %{
                failure_count: lesson.failure_count + 1,
                last_outcome: "failure",
                last_applied_at: DateTime.utc_now() |> DateTime.truncate(:second)
              }
          end

        updated_lesson = struct(lesson, updates)
        new_confidence = recalculate_confidence(updated_lesson)
        final_updates = Map.put(updates, :confidence, new_confidence)

        lesson
        |> LessonSchema.changeset(final_updates)
        |> Repo.update()
    end
  end

  @doc "Deactivates a lesson (soft delete)."
  @spec deactivate(binary()) :: {:ok, LessonSchema.t()} | {:error, term()}
  def deactivate(lesson_id) do
    case Repo.get(LessonSchema, lesson_id) do
      nil -> {:error, :not_found}
      lesson -> lesson |> LessonSchema.changeset(%{active: false}) |> Repo.update()
    end
  end

  @doc """
  Recalculates composite confidence score from the four scoring factors.
  """
  @spec recalculate_confidence(LessonSchema.t()) :: float()
  def recalculate_confidence(%LessonSchema{} = l) do
    success_rate = success_rate(l.success_count, l.failure_count)
    recency = recency_score(l.last_applied_at)
    extraction = l.extraction_confidence || 0.5
    penalty = min(1.0, l.contradiction_penalty || 0.0)

    raw = success_rate * 0.40 + recency * 0.25 + extraction * 0.15 + (1.0 - penalty) * 0.20
    Float.round(clamp(raw, 0.0, 1.0), 4)
  end

  @doc """
  Computes Jaccard similarity between two strings based on word sets.
  """
  @spec jaccard_similarity(String.t(), String.t()) :: float()
  def jaccard_similarity(a, b) when is_binary(a) and is_binary(b) do
    set_a = words(a)
    set_b = words(b)

    intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()

    if union == 0, do: 0.0, else: intersection / union
  end

  @doc "Returns all active lessons for an agent."
  @spec list_active(String.t()) :: [LessonSchema.t()]
  def list_active(agent_id) do
    from(l in LessonSchema, where: l.agent_id == ^agent_id and l.active == true)
    |> Repo.all()
  end

  # --- Private ---

  defp duplicate?(content, existing) do
    Enum.any?(existing, fn lesson ->
      jaccard_similarity(content, lesson.content) >= @novelty_threshold
    end)
  end

  defp success_rate(0, 0), do: 0.5
  defp success_rate(s, f), do: s / (s + f)

  defp recency_score(nil), do: 0.5

  defp recency_score(%DateTime{} = last_applied) do
    days_ago = DateTime.diff(DateTime.utc_now(), last_applied, :second) / 86_400
    :math.pow(0.5, days_ago / @recency_half_life_days)
  end

  defp words(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9áàãâéêíóôõúüç]+/u, trim: true)
    |> MapSet.new()
  end

  defp clamp(value, min_val, max_val), do: max(min_val, min(max_val, value))
end
