defmodule Pincer.Core.DeadLetterQueue do
  @moduledoc """
  Dead Letter Queue for failed operations that could not be recovered automatically.

  When an LLM request, tool execution, or channel message delivery fails
  after all retries are exhausted, the operation is enqueued here for
  manual review or automated reprocessing.

  Operations:
  - `enqueue/3` — record a failed operation
  - `pending/1` — list unresolved entries by type
  - `resolve/2` — mark an entry as resolved (manual or automated)
  - `retry_pending/2` — attempt to replay a failed operation
  """
  use Ecto.Schema
  import Ecto.Changeset

  require Logger

  alias Pincer.Infra.SQLite

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "dead_letter_queue" do
    field(:operation_type, :string)
    field(:payload, :map)
    field(:error, :string)
    field(:attempt_count, :integer, default: 1)
    field(:last_attempted_at, :utc_datetime_usec)
    field(:resolved_at, :utc_datetime_usec)
    field(:resolution, :string)

    timestamps()
  end

  @required [:operation_type, :payload]
  @optional [:error, :attempt_count, :last_attempted_at, :resolved_at, :resolution]

  def changeset(struct \\ %__MODULE__{}, params) do
    struct
    |> cast(params, @required ++ @optional)
    |> validate_required(@required)
  end

  @doc "Enqueue a failed operation into the DLQ."
  @spec enqueue(String.t(), map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def enqueue(operation_type, payload, error \\ nil) do
    params = %{
      operation_type: operation_type,
      payload: payload,
      error: error && String.slice(inspect(error), 0, 2000),
      last_attempted_at: DateTime.utc_now()
    }

    changeset = changeset(%__MODULE__{}, params)

    result = sqlite_insert(changeset)

    result
    |> tap(fn
      {:ok, entry} ->
        Logger.warning("DLQ: enqueued #{operation_type} (id=#{entry.id}). Error: #{error}")

      {:error, reason} ->
        Logger.error("DLQ: failed to enqueue #{operation_type}: #{inspect(reason)}")
    end)
  end

  @doc "List unresolved DLQ entries, optionally filtered by operation_type."
  @spec pending(String.t() | nil) :: [%__MODULE__{}]
  def pending(operation_type \\ nil) do
    sqlite_pending(operation_type)
  end

  @doc "Mark a DLQ entry as resolved."
  @spec resolve(binary(), String.t()) :: {:ok, term()} | {:error, term()}
  def resolve(id, resolution \\ "manual") do
    case fetch_entry(id) do
      nil ->
        {:error, :not_found}

      entry ->
        changeset = changeset(entry, %{resolved_at: DateTime.utc_now(), resolution: resolution})
        sqlite_update(changeset)
    end
  end

  @doc "Increment attempt count and update last_attempted_at for an entry."
  @spec increment_attempt(binary()) :: {:ok, term()} | {:error, term()}
  def increment_attempt(id) do
    case fetch_entry(id) do
      nil ->
        {:error, :not_found}

      entry ->
        changeset =
          changeset(entry, %{
            attempt_count: entry.attempt_count + 1,
            last_attempted_at: DateTime.utc_now()
          })

        sqlite_update(changeset)
    end
  end

  # --- SQLite persistence helpers ---

  defp fetch_entry(id) do
    sqlite_get(id)
  end

  defp sqlite_insert(changeset) do
    if changeset.valid? do
      now = DateTime.utc_now()
      now_str = DateTime.to_iso8601(now)
      e = %{apply_changes(changeset) | id: SQLite.uuid(), inserted_at: now, updated_at: now}

      case SQLite.execute(
             SQLite.default_server(),
             """
             INSERT INTO dead_letter_queue
               (id, operation_type, payload, error, attempt_count, last_attempted_at,
                resolved_at, resolution, inserted_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
             """,
             [
               e.id,
               e.operation_type,
               Jason.encode!(e.payload || %{}),
               e.error,
               e.attempt_count || 1,
               e.last_attempted_at && DateTime.to_iso8601(e.last_attempted_at),
               e.resolved_at && DateTime.to_iso8601(e.resolved_at),
               e.resolution,
               now_str,
               now_str
             ]
           ) do
        :ok -> {:ok, e}
        error -> error
      end
    else
      {:error, changeset}
    end
  end

  defp sqlite_update(changeset) do
    if changeset.valid? do
      now = DateTime.utc_now()
      now_str = DateTime.to_iso8601(now)
      e = %{apply_changes(changeset) | updated_at: now}

      case SQLite.execute(
             SQLite.default_server(),
             """
             UPDATE dead_letter_queue
             SET attempt_count = ?1, last_attempted_at = ?2, resolved_at = ?3,
                 resolution = ?4, updated_at = ?5
             WHERE id = ?6
             """,
             [
               e.attempt_count || 1,
               e.last_attempted_at && DateTime.to_iso8601(e.last_attempted_at),
               e.resolved_at && DateTime.to_iso8601(e.resolved_at),
               e.resolution,
               now_str,
               e.id
             ]
           ) do
        :ok -> {:ok, e}
        error -> error
      end
    else
      {:error, changeset}
    end
  end

  defp sqlite_get(id) do
    case SQLite.query(
           SQLite.default_server(),
           """
           SELECT id, operation_type, payload, error, attempt_count, last_attempted_at,
                  resolved_at, resolution, inserted_at, updated_at
           FROM dead_letter_queue
           WHERE id = ?1
           LIMIT 1
           """,
           [to_string(id)]
         ) do
      {:ok, %{rows: [row]}} -> hydrate_entry(row)
      _ -> nil
    end
  end

  defp sqlite_pending(nil) do
    case SQLite.query(
           SQLite.default_server(),
           """
           SELECT id, operation_type, payload, error, attempt_count, last_attempted_at,
                  resolved_at, resolution, inserted_at, updated_at
           FROM dead_letter_queue
           WHERE resolved_at IS NULL
           ORDER BY inserted_at ASC, rowid ASC
           """
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &hydrate_entry/1)
      _ -> []
    end
  end

  defp sqlite_pending(op_type) do
    case SQLite.query(
           SQLite.default_server(),
           """
           SELECT id, operation_type, payload, error, attempt_count, last_attempted_at,
                  resolved_at, resolution, inserted_at, updated_at
           FROM dead_letter_queue
           WHERE resolved_at IS NULL AND operation_type = ?1
           ORDER BY inserted_at ASC, rowid ASC
           """,
           [to_string(op_type)]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &hydrate_entry/1)
      _ -> []
    end
  end

  defp hydrate_entry([id, op, payload, error, attempts, last_at, resolved_at, res, ins, upd]) do
    %__MODULE__{
      id: id,
      operation_type: op,
      payload: decode_payload(payload),
      error: error,
      attempt_count: attempts,
      last_attempted_at: SQLite.parse_datetime(last_at),
      resolved_at: SQLite.parse_datetime(resolved_at),
      resolution: res,
      inserted_at: SQLite.parse_datetime(ins),
      updated_at: SQLite.parse_datetime(upd)
    }
  end

  defp decode_payload(bin) do
    case SQLite.decode_json(bin, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end
end
