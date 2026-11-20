defmodule Pincer.Core.Introspection.SelfState do
  @moduledoc """
  Domain logic for agent introspective self-state.

  Provides loading, updating, and serialization of the agent's
  internal awareness. One `SelfState` row exists per agent,
  keyed by `agent_id`.
  """

  alias Pincer.Core.Introspection.Mood
  alias Pincer.Core.Introspection.Schema
  alias Pincer.Infra.Repo
  alias Pincer.Infra.SQLite

  import Ecto.Query, only: [from: 2]
  import Ecto.Changeset, only: [apply_changes: 1]

  @doc """
  Loads the self-state for the given agent, creating a default row
  if none exists.
  """
  @spec load_or_create(String.t()) :: {:ok, Schema.t()} | {:error, term()}
  def load_or_create(agent_id) do
    if SQLite.sqlite_mode?() do
      sqlite_load_or_create(agent_id)
    else
      case Repo.one(from(s in Schema, where: s.agent_id == ^agent_id)) do
        %Schema{} = state ->
          {:ok, state}

        nil ->
          %Schema{}
          |> Schema.changeset(%{agent_id: agent_id})
          |> Repo.insert()
      end
    end
  end

  @doc """
  Updates the self-state for the given agent.

  Only the provided keys in `attrs` are updated; other fields
  remain unchanged.
  """
  @spec update(String.t(), map()) :: {:ok, Schema.t()} | {:error, term()}
  def update(agent_id, attrs) do
    if SQLite.sqlite_mode?() do
      sqlite_update(agent_id, attrs)
    else
      case Repo.one(from(s in Schema, where: s.agent_id == ^agent_id)) do
        nil ->
          {:error, :not_found}

        %Schema{} = state ->
          state
          |> Schema.changeset(Map.new(attrs))
          |> Repo.update()
      end
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

  # --- SQLite persistence ---

  defp sqlite_load_or_create(agent_id) do
    case sqlite_get(agent_id) do
      {:ok, %Schema{} = state} ->
        {:ok, state}

      {:ok, nil} ->
        changeset = Schema.changeset(%Schema{}, %{agent_id: agent_id})

        if changeset.valid? do
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          now_str = DateTime.to_iso8601(now)
          s = %{apply_changes(changeset) | id: SQLite.uuid(), inserted_at: now, updated_at: now}

          case SQLite.execute(
                 SQLite.default_server(),
                 """
                 INSERT INTO self_states
                   (id, agent_id, wakefulness, focus, concerns, open_questions, work_lanes,
                    last_reflection_summary, mood_valence, mood_arousal, meta, inserted_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                 """,
                 [
                   s.id,
                   s.agent_id,
                   s.wakefulness || "idle",
                   s.focus || "",
                   Jason.encode!(s.concerns || []),
                   Jason.encode!(s.open_questions || []),
                   Jason.encode!(s.work_lanes || []),
                   s.last_reflection_summary || "",
                   (s.mood_valence || 0.0) * 1.0,
                   (s.mood_arousal || 0.0) * 1.0,
                   Jason.encode!(s.meta || %{}),
                   now_str,
                   now_str
                 ]
               ) do
            :ok -> {:ok, s}
            error -> error
          end
        else
          {:error, changeset}
        end

      error ->
        error
    end
  end

  defp sqlite_update(agent_id, attrs) do
    case sqlite_get(agent_id) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, %Schema{} = existing} ->
        changeset = Schema.changeset(existing, Map.new(attrs))

        if changeset.valid? do
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          now_str = DateTime.to_iso8601(now)
          updated = %{apply_changes(changeset) | updated_at: now}

          case SQLite.execute(
                 SQLite.default_server(),
                 """
                 UPDATE self_states
                 SET wakefulness = ?1, focus = ?2, concerns = ?3, open_questions = ?4,
                     work_lanes = ?5, last_reflection_summary = ?6, mood_valence = ?7,
                     mood_arousal = ?8, meta = ?9, updated_at = ?10
                 WHERE agent_id = ?11
                 """,
                 [
                   updated.wakefulness || "idle",
                   updated.focus || "",
                   Jason.encode!(updated.concerns || []),
                   Jason.encode!(updated.open_questions || []),
                   Jason.encode!(updated.work_lanes || []),
                   updated.last_reflection_summary || "",
                   (updated.mood_valence || 0.0) * 1.0,
                   (updated.mood_arousal || 0.0) * 1.0,
                   Jason.encode!(updated.meta || %{}),
                   now_str,
                   agent_id
                 ]
               ) do
            :ok -> {:ok, updated}
            error -> error
          end
        else
          {:error, changeset}
        end

      error ->
        error
    end
  end

  defp sqlite_get(agent_id) do
    case SQLite.query(
           SQLite.default_server(),
           """
           SELECT id, agent_id, wakefulness, focus, concerns, open_questions, work_lanes,
                  last_reflection_summary, mood_valence, mood_arousal, meta, inserted_at, updated_at
           FROM self_states
           WHERE agent_id = ?1
           LIMIT 1
           """,
           [agent_id]
         ) do
      {:ok, %{rows: []}} ->
        {:ok, nil}

      {:ok,
       %{
         rows: [
           [
             id,
             aid,
             wake,
             focus,
             concerns,
             open_q,
             work_lanes,
             summary,
             val,
             arousal,
             meta,
             ins,
             upd
           ]
         ]
       }} ->
        {:ok,
         %Schema{
           id: id,
           agent_id: aid,
           wakefulness: wake,
           focus: focus || "",
           concerns: SQLite.decode_json(concerns, []),
           open_questions: SQLite.decode_json(open_q, []),
           work_lanes: SQLite.decode_json(work_lanes, []),
           last_reflection_summary: summary || "",
           mood_valence: val || 0.0,
           mood_arousal: arousal || 0.0,
           meta: SQLite.decode_json(meta, %{}),
           inserted_at: SQLite.parse_datetime(ins),
           updated_at: SQLite.parse_datetime(upd)
         }}

      error ->
        error
    end
  end
end
