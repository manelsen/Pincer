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

  alias Pincer.Core.Introspection.LessonSchema
  alias Pincer.Infra.SQLite

  import Pincer.Utils.Validation, only: [apply_changes: 1]

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
      changeset = LessonSchema.changeset(%LessonSchema{}, Map.put(attrs, :agent_id, agent_id))
      sqlite_insert(changeset)
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

    sqlite_top_lessons(agent_id, limit, min_conf)
  end

  @doc """
  Records a turn outcome for a lesson and recalculates confidence.
  """
  @spec record_outcome(binary(), :success | :failure) ::
          {:ok, LessonSchema.t()} | {:error, term()}
  def record_outcome(lesson_id, outcome) when outcome in [:success, :failure] do
    case fetch_lesson(lesson_id) do
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

        changeset = LessonSchema.changeset(lesson, final_updates)
        persist_update(changeset)
    end
  end

  @doc "Deactivates a lesson (soft delete)."
  @spec deactivate(binary()) :: {:ok, LessonSchema.t()} | {:error, term()}
  def deactivate(lesson_id) do
    case fetch_lesson(lesson_id) do
      nil -> {:error, :not_found}
      lesson -> lesson |> LessonSchema.changeset(%{active: false}) |> persist_update()
    end
  end

  @doc """
  Marks one or more lessons as promoted into a generated workspace skill.
  """
  @spec mark_promoted(binary() | [binary()], String.t()) :: :ok | {:error, term()}
  def mark_promoted([], _skill_name), do: :ok

  def mark_promoted(lesson_ids, skill_name)
      when is_list(lesson_ids) and is_binary(skill_name) do
    promoted_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Enum.each(lesson_ids, fn id ->
      mark_promoted(id, skill_name, promoted_at)
    end)

    :ok
  end

  def mark_promoted(lesson_id, skill_name) when is_binary(skill_name) do
    promoted_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    mark_promoted(lesson_id, skill_name, promoted_at)
  end

  defp mark_promoted(lesson_id, skill_name, promoted_at) do
    case fetch_lesson(lesson_id) do
      nil ->
        {:error, :not_found}

      lesson ->
        next_meta =
          lesson.meta
          |> Map.put("promoted_skill", skill_name)
          |> Map.put("promoted_at", promoted_at)

        case lesson |> LessonSchema.changeset(%{meta: next_meta}) |> persist_update() do
          {:ok, _} -> :ok
          error -> error
        end
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
    sqlite_list_active(agent_id)
  end

  # --- Private ---

  defp fetch_lesson(lesson_id) do
    sqlite_get(lesson_id)
  end

  defp persist_update(changeset) do
    sqlite_update(changeset)
  end

  defp sqlite_insert(changeset) do
    if changeset.valid? do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      now_str = DateTime.to_iso8601(now)
      l = %{apply_changes(changeset) | id: SQLite.uuid(), inserted_at: now, updated_at: now}

      case SQLite.execute(
             SQLite.default_server(),
             """
             INSERT INTO lessons
               (id, agent_id, content, source, confidence, extraction_confidence,
                success_count, failure_count, contradiction_penalty, active,
                last_applied_at, last_outcome, meta, inserted_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
             """,
             [
               l.id,
               l.agent_id,
               l.content,
               l.source || "reflection",
               (l.confidence || 0.5) * 1.0,
               (l.extraction_confidence || 0.5) * 1.0,
               l.success_count || 0,
               l.failure_count || 0,
               (l.contradiction_penalty || 0.0) * 1.0,
               if(l.active == false, do: 0, else: 1),
               l.last_applied_at && DateTime.to_iso8601(l.last_applied_at),
               l.last_outcome,
               Jason.encode!(l.meta || %{}),
               now_str,
               now_str
             ]
           ) do
        :ok -> {:ok, l}
        error -> error
      end
    else
      {:error, changeset}
    end
  end

  defp sqlite_update(changeset) do
    if changeset.valid? do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      now_str = DateTime.to_iso8601(now)
      l = %{apply_changes(changeset) | updated_at: now}

      case SQLite.execute(
             SQLite.default_server(),
             """
             UPDATE lessons
             SET confidence = ?1, success_count = ?2, failure_count = ?3,
                 contradiction_penalty = ?4, active = ?5, last_applied_at = ?6,
                 last_outcome = ?7, meta = ?8, updated_at = ?9
             WHERE id = ?10
             """,
             [
               (l.confidence || 0.5) * 1.0,
               l.success_count || 0,
               l.failure_count || 0,
               (l.contradiction_penalty || 0.0) * 1.0,
               if(l.active == false, do: 0, else: 1),
               l.last_applied_at && DateTime.to_iso8601(l.last_applied_at),
               l.last_outcome,
               Jason.encode!(l.meta || %{}),
               now_str,
               l.id
             ]
           ) do
        :ok -> {:ok, l}
        error -> error
      end
    else
      {:error, changeset}
    end
  end

  defp sqlite_get(lesson_id) do
    case SQLite.query(
           SQLite.default_server(),
           """
           SELECT id, agent_id, content, source, confidence, extraction_confidence,
                  success_count, failure_count, contradiction_penalty, active,
                  last_applied_at, last_outcome, meta, inserted_at, updated_at
           FROM lessons
           WHERE id = ?1
           LIMIT 1
           """,
           [lesson_id]
         ) do
      {:ok, %{rows: [row]}} -> hydrate_lesson(row)
      _ -> nil
    end
  end

  defp sqlite_top_lessons(agent_id, limit, min_conf) do
    case SQLite.query(
           SQLite.default_server(),
           """
           SELECT id, agent_id, content, source, confidence, extraction_confidence,
                  success_count, failure_count, contradiction_penalty, active,
                  last_applied_at, last_outcome, meta, inserted_at, updated_at
           FROM lessons
           WHERE agent_id = ?1 AND active = 1 AND confidence >= ?2
           ORDER BY confidence DESC
           LIMIT ?3
           """,
           [agent_id, min_conf * 1.0, limit]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &hydrate_lesson/1)
      _ -> []
    end
  end

  defp sqlite_list_active(agent_id) do
    case SQLite.query(
           SQLite.default_server(),
           """
           SELECT id, agent_id, content, source, confidence, extraction_confidence,
                  success_count, failure_count, contradiction_penalty, active,
                  last_applied_at, last_outcome, meta, inserted_at, updated_at
           FROM lessons
           WHERE agent_id = ?1 AND active = 1
           """,
           [agent_id]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &hydrate_lesson/1)
      _ -> []
    end
  end

  defp hydrate_lesson([
         id,
         agent_id,
         content,
         source,
         confidence,
         ext_conf,
         succ,
         fail,
         penalty,
         active,
         last_applied_at,
         last_outcome,
         meta_json,
         ins,
         upd
       ]) do
    %LessonSchema{
      id: id,
      agent_id: agent_id,
      content: content,
      source: source,
      confidence: confidence,
      extraction_confidence: ext_conf,
      success_count: succ,
      failure_count: fail,
      contradiction_penalty: penalty,
      active: active == 1,
      last_applied_at: SQLite.parse_datetime(last_applied_at),
      last_outcome: last_outcome,
      meta: decode_meta(meta_json),
      inserted_at: SQLite.parse_datetime(ins),
      updated_at: SQLite.parse_datetime(upd)
    }
  end

  defp decode_meta(bin) do
    case SQLite.decode_json(bin, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

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
