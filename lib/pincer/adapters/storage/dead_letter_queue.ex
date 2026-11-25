defmodule Pincer.Adapters.Storage.DeadLetterQueue do
  @moduledoc "SQLite persistence for unresolved and retried operations."

  @behaviour Pincer.Ports.DeadLetterQueue

  alias Pincer.Infra.SQLite

  @columns """
  id, operation_type, payload, error, attempt_count, last_attempted_at,
  resolved_at, resolution, inserted_at, updated_at
  """

  @impl true
  @doc "Inserts a failed operation and returns the stored entry."
  def insert(entry) do
    now = DateTime.utc_now()
    now_string = DateTime.to_iso8601(now)
    entry = %{entry | id: SQLite.uuid(), inserted_at: now, updated_at: now}

    case SQLite.execute(
           SQLite.default_server(),
           "INSERT INTO dead_letter_queue (#{@columns}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
           [
             entry.id,
             entry.operation_type,
             Jason.encode!(entry.payload || %{}),
             entry.error,
             entry.attempt_count || 1,
             encode_datetime(entry.last_attempted_at),
             encode_datetime(entry.resolved_at),
             entry.resolution,
             now_string,
             now_string
           ]
         ) do
      :ok -> {:ok, entry}
      error -> error
    end
  end

  @impl true
  @doc "Reads pending entries in enqueue order."
  def pending(operation_type) do
    {clause, params} =
      case operation_type do
        nil -> {"", []}
        type -> {"AND operation_type = ?", [to_string(type)]}
      end

    sql = """
    SELECT #{@columns}
    FROM dead_letter_queue
    WHERE resolved_at IS NULL #{clause}
    ORDER BY inserted_at ASC, rowid ASC
    """

    case SQLite.query(SQLite.default_server(), sql, params) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &decode_entry/1)
      _ -> []
    end
  end

  @impl true
  @doc "Marks an entry as resolved without changing its attempt count."
  def resolve(id, resolution, now) do
    timestamp = DateTime.to_iso8601(now)

    update(id, "resolved_at = ?, resolution = ?, updated_at = ?", [
      timestamp,
      resolution,
      timestamp
    ])
  end

  @impl true
  @doc "Increments the count in the database without overwriting the entry's resolution."
  def increment_attempt(id, now) do
    timestamp = DateTime.to_iso8601(now)

    update(id, "attempt_count = attempt_count + 1, last_attempted_at = ?, updated_at = ?", [
      timestamp,
      timestamp
    ])
  end

  defp update(id, assignments, params) do
    sql = "UPDATE dead_letter_queue SET #{assignments} WHERE id = ? RETURNING #{@columns}"

    case SQLite.query(SQLite.default_server(), sql, params ++ [to_string(id)]) do
      {:ok, %{rows: [row]}} -> {:ok, decode_entry(row)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      error -> error
    end
  end

  defp decode_entry([id, type, payload, error, count, attempted, resolved, resolution, ins, upd]) do
    %{
      id: id,
      operation_type: type,
      payload: decode_payload(payload),
      error: error,
      attempt_count: count,
      last_attempted_at: SQLite.parse_datetime(attempted),
      resolved_at: SQLite.parse_datetime(resolved),
      resolution: resolution,
      inserted_at: SQLite.parse_datetime(ins),
      updated_at: SQLite.parse_datetime(upd)
    }
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(datetime), do: DateTime.to_iso8601(datetime)

  defp decode_payload(json) do
    case SQLite.decode_json(json, %{}) do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end
end
