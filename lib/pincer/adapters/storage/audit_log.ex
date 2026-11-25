defmodule Pincer.Adapters.Storage.AuditLog do
  @moduledoc "SQLite persistence for security audit events."

  @behaviour Pincer.Ports.AuditLog

  alias Pincer.Infra.SQLite

  @impl true
  @doc "Writes an audit event to the embedded database."
  def insert(event) do
    SQLite.execute(
      SQLite.default_server(),
      """
      INSERT INTO audit_log
        (id, event_type, actor, target, channel, session_id, outcome, metadata, inserted_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        SQLite.uuid(),
        event.event_type,
        event.actor,
        event.target,
        event.channel,
        event.session_id,
        event.outcome,
        Jason.encode!(event.metadata || %{}),
        DateTime.utc_now() |> DateTime.to_iso8601()
      ]
    )
  end

  @impl true
  @doc "Reads audit events in descending insertion order with an optional filter."
  def list(filter, limit) do
    {clause, params} = filter_params(filter)

    sql = """
    SELECT id, event_type, actor, target, channel, session_id, outcome, metadata, inserted_at
    FROM audit_log
    #{clause}
    ORDER BY inserted_at DESC, rowid DESC
    LIMIT ?
    """

    case SQLite.query(SQLite.default_server(), sql, params ++ [limit]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &decode_event/1)
      _ -> []
    end
  end

  defp filter_params(:all), do: {"", []}
  defp filter_params({:actor, actor}), do: {"WHERE actor = ?", [actor]}
  defp filter_params({:type, type}), do: {"WHERE event_type = ?", [type]}

  defp decode_event([
         id,
         type,
         actor,
         target,
         channel,
         session_id,
         outcome,
         metadata,
         inserted_at
       ]) do
    %{
      id: id,
      event_type: type,
      actor: actor,
      target: target,
      channel: channel,
      session_id: session_id,
      outcome: outcome,
      metadata: decode_metadata(metadata),
      inserted_at: SQLite.parse_datetime(inserted_at)
    }
  end

  defp decode_metadata(json) do
    case SQLite.decode_json(json, %{}) do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
  end
end
