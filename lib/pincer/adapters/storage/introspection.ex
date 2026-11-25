defmodule Pincer.Adapters.Storage.Introspection do
  @moduledoc "SQLite persistence for introspection lessons and agent self-state."

  @behaviour Pincer.Ports.IntrospectionStore

  alias Pincer.Infra.SQLite

  @lesson_columns """
  id, agent_id, content, source, confidence, extraction_confidence,
  success_count, failure_count, contradiction_penalty, active,
  last_applied_at, last_outcome, meta, inserted_at, updated_at
  """

  @state_columns """
  id, agent_id, wakefulness, focus, concerns, open_questions, work_lanes,
  last_reflection_summary, mood_valence, mood_arousal, meta, inserted_at, updated_at
  """

  @impl true
  @doc "Inserts a new lesson and returns its generated metadata."
  def insert_lesson(lesson) do
    now = utc_now()
    timestamp = DateTime.to_iso8601(now)
    lesson = %{lesson | id: SQLite.uuid(), inserted_at: now, updated_at: now}

    sql = """
    INSERT INTO lessons (#{@lesson_columns})
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    persist(
      sql,
      [
        lesson.id,
        lesson.agent_id,
        lesson.content,
        lesson.source || "reflection",
        (lesson.confidence || 0.5) * 1.0,
        (lesson.extraction_confidence || 0.5) * 1.0,
        lesson.success_count || 0,
        lesson.failure_count || 0,
        (lesson.contradiction_penalty || 0.0) * 1.0,
        encode_active(lesson.active),
        encode_datetime(lesson.last_applied_at),
        lesson.last_outcome,
        Jason.encode!(lesson.meta || %{}),
        timestamp,
        timestamp
      ],
      lesson
    )
  end

  @impl true
  @doc "Writes the mutable fields of an existing lesson."
  def update_lesson(lesson) do
    lesson = %{lesson | updated_at: utc_now()}

    sql = """
    UPDATE lessons
    SET confidence = ?, success_count = ?, failure_count = ?, contradiction_penalty = ?,
        active = ?, last_applied_at = ?, last_outcome = ?, meta = ?, updated_at = ?
    WHERE id = ?
    """

    persist(
      sql,
      [
        (lesson.confidence || 0.5) * 1.0,
        lesson.success_count || 0,
        lesson.failure_count || 0,
        (lesson.contradiction_penalty || 0.0) * 1.0,
        encode_active(lesson.active),
        encode_datetime(lesson.last_applied_at),
        lesson.last_outcome,
        Jason.encode!(lesson.meta || %{}),
        DateTime.to_iso8601(lesson.updated_at),
        lesson.id
      ],
      lesson
    )
  end

  @impl true
  @doc "Finds a stored lesson by ID."
  def get_lesson(lesson_id) do
    case query("SELECT #{@lesson_columns} FROM lessons WHERE id = ? LIMIT 1", [lesson_id]) do
      {:ok, %{rows: [row]}} -> decode_lesson(row)
      _ -> nil
    end
  end

  @impl true
  @doc "Lists active lessons with the optional confidence cut-off and result limit."
  def list_lessons(agent_id, mode) do
    {clause, params} =
      case mode do
        :active ->
          {"", [agent_id]}

        {:top, limit, min_confidence} ->
          {"AND confidence >= ? ORDER BY confidence DESC LIMIT ?",
           [agent_id, min_confidence * 1.0, limit]}
      end

    sql = "SELECT #{@lesson_columns} FROM lessons WHERE agent_id = ? AND active = 1 #{clause}"

    case query(sql, params) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &decode_lesson/1)
      _ -> []
    end
  end

  @impl true
  @doc "Finds the self-state of an agent."
  def get_self_state(agent_id) do
    case query("SELECT #{@state_columns} FROM self_states WHERE agent_id = ? LIMIT 1", [agent_id]) do
      {:ok, %{rows: []}} -> {:ok, nil}
      {:ok, %{rows: [row]}} -> {:ok, decode_state(row)}
      error -> error
    end
  end

  @impl true
  @doc "Inserts the initial self-state or reads an existing state created concurrently."
  def insert_self_state(state) do
    now = utc_now()
    timestamp = DateTime.to_iso8601(now)
    state = %{state | id: SQLite.uuid(), inserted_at: now, updated_at: now}

    sql = """
    INSERT INTO self_states (#{@state_columns})
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(agent_id) DO NOTHING
    RETURNING id
    """

    params = [state.id, state.agent_id] ++ state_values(state) ++ [timestamp, timestamp]

    case query(sql, params) do
      {:ok, %{rows: [[_id]]}} -> {:ok, state}
      {:ok, %{rows: []}} -> get_self_state(state.agent_id)
      error -> error
    end
  end

  @impl true
  @doc "Writes the mutable self-state fields for an existing agent."
  def update_self_state(agent_id, state) do
    state = %{state | updated_at: utc_now()}

    sql = """
    UPDATE self_states
    SET wakefulness = ?, focus = ?, concerns = ?, open_questions = ?, work_lanes = ?,
        last_reflection_summary = ?, mood_valence = ?, mood_arousal = ?, meta = ?, updated_at = ?
    WHERE agent_id = ?
    """

    params = state_values(state) ++ [DateTime.to_iso8601(state.updated_at), agent_id]
    persist(sql, params, state)
  end

  defp persist(sql, params, saved) do
    case SQLite.execute(SQLite.default_server(), sql, params) do
      :ok -> {:ok, saved}
      error -> error
    end
  end

  defp query(sql, params), do: SQLite.query(SQLite.default_server(), sql, params)

  defp state_values(state) do
    [
      state.wakefulness || "idle",
      state.focus || "",
      Jason.encode!(state.concerns || []),
      Jason.encode!(state.open_questions || []),
      Jason.encode!(state.work_lanes || []),
      state.last_reflection_summary || "",
      (state.mood_valence || 0.0) * 1.0,
      (state.mood_arousal || 0.0) * 1.0,
      Jason.encode!(state.meta || %{})
    ]
  end

  defp decode_lesson([
         id,
         agent_id,
         content,
         source,
         confidence,
         extraction_confidence,
         success_count,
         failure_count,
         penalty,
         active,
         last_applied_at,
         last_outcome,
         meta,
         inserted_at,
         updated_at
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      content: content,
      source: source,
      confidence: confidence,
      extraction_confidence: extraction_confidence,
      success_count: success_count,
      failure_count: failure_count,
      contradiction_penalty: penalty,
      active: active == 1,
      last_applied_at: SQLite.parse_datetime(last_applied_at),
      last_outcome: last_outcome,
      meta: decode_lesson_meta(meta),
      inserted_at: SQLite.parse_datetime(inserted_at),
      updated_at: SQLite.parse_datetime(updated_at)
    }
  end

  defp decode_state([
         id,
         agent_id,
         wake,
         focus,
         concerns,
         questions,
         lanes,
         summary,
         valence,
         arousal,
         meta,
         inserted_at,
         updated_at
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      wakefulness: wake,
      focus: focus || "",
      concerns: SQLite.decode_json(concerns, []),
      open_questions: SQLite.decode_json(questions, []),
      work_lanes: SQLite.decode_json(lanes, []),
      last_reflection_summary: summary || "",
      mood_valence: valence || 0.0,
      mood_arousal: arousal || 0.0,
      meta: SQLite.decode_json(meta, %{}),
      inserted_at: SQLite.parse_datetime(inserted_at),
      updated_at: SQLite.parse_datetime(updated_at)
    }
  end

  defp decode_lesson_meta(json) do
    case SQLite.decode_json(json, %{}) do
      meta when is_map(meta) -> meta
      _ -> %{}
    end
  end

  defp encode_active(false), do: 0
  defp encode_active(_), do: 1
  defp encode_datetime(nil), do: nil
  defp encode_datetime(datetime), do: DateTime.to_iso8601(datetime)
  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
