defmodule Pincer.Core.AuditLog do
  @moduledoc """
  Persistent audit log for security-relevant events.
  Every tool approval, policy denial, auth failure, and RBAC decision
  is written here for compliance and post-incident analysis.
  """
  import Pincer.Utils.Validation

  alias Pincer.Infra.SQLite

  defstruct id: nil,
            event_type: nil,
            actor: nil,
            target: nil,
            channel: nil,
            session_id: nil,
            outcome: nil,
            metadata: %{},
            inserted_at: nil

  @required [:event_type, :outcome]
  @optional [:actor, :target, :channel, :session_id, :metadata]

  def changeset(struct \\ %__MODULE__{}, params) do
    struct
    |> cast(params, @required ++ @optional)
    |> validate_required(@required)
  end

  @doc "Record an audit event. Fails silently to avoid disrupting the main flow."
  def record(event_type, outcome, opts \\ []) do
    params = %{
      event_type: to_string(event_type),
      outcome: to_string(outcome),
      actor: opts[:actor],
      target: opts[:target],
      channel: opts[:channel],
      session_id: opts[:session_id],
      metadata: opts[:metadata] || %{}
    }

    changeset = changeset(%__MODULE__{}, params)

    case sqlite_insert(changeset) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("AuditLog.record failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Query recent audit events, newest first."
  def recent(limit \\ 100) do
    sqlite_query("ORDER BY inserted_at DESC, rowid DESC LIMIT ?1", [limit])
  end

  @doc "Query audit events by actor."
  def by_actor(actor, limit \\ 50) do
    sqlite_query("WHERE actor = ?1 ORDER BY inserted_at DESC, rowid DESC LIMIT ?2", [
      actor,
      limit
    ])
  end

  @doc "Query audit events by event type."
  def by_type(event_type, limit \\ 50) do
    sqlite_query(
      "WHERE event_type = ?1 ORDER BY inserted_at DESC, rowid DESC LIMIT ?2",
      [event_type, limit]
    )
  end

  defp sqlite_insert(changeset) do
    if changeset.valid? do
      now = DateTime.utc_now()
      a = %{apply_changes(changeset) | id: SQLite.uuid(), inserted_at: now}

      case SQLite.execute(
             SQLite.default_server(),
             """
             INSERT INTO audit_log
               (id, event_type, actor, target, channel, session_id, outcome, metadata, inserted_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             """,
             [
               a.id,
               a.event_type,
               a.actor,
               a.target,
               a.channel,
               a.session_id,
               a.outcome,
               Jason.encode!(a.metadata || %{}),
               DateTime.to_iso8601(now)
             ]
           ) do
        :ok -> {:ok, a}
        error -> error
      end
    else
      {:error, changeset}
    end
  end

  defp sqlite_query(clause, params) do
    case SQLite.query(
           SQLite.default_server(),
           """
           SELECT id, event_type, actor, target, channel, session_id, outcome, metadata, inserted_at
           FROM audit_log
           #{clause}
           """,
           params
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id, evt, actor, target, channel, sid, outcome, meta, ins] ->
          %__MODULE__{
            id: id,
            event_type: evt,
            actor: actor,
            target: target,
            channel: channel,
            session_id: sid,
            outcome: outcome,
            metadata: decode_meta(meta),
            inserted_at: SQLite.parse_datetime(ins)
          }
        end)

      _ ->
        []
    end
  end

  defp decode_meta(bin) do
    case SQLite.decode_json(bin, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end
end
