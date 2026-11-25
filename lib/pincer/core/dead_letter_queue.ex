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
  import Pincer.Utils.Validation

  require Logger

  alias Pincer.Ports.DeadLetterQueue, as: Store

  defstruct id: nil,
            operation_type: nil,
            payload: nil,
            error: nil,
            attempt_count: 1,
            last_attempted_at: nil,
            resolved_at: nil,
            resolution: nil,
            inserted_at: nil,
            updated_at: nil

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

    result = insert(changeset)

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
    Store.pending(operation_type)
    |> Enum.map(&struct!(__MODULE__, &1))
  end

  @doc "Mark a DLQ entry as resolved."
  @spec resolve(binary(), String.t()) :: {:ok, term()} | {:error, term()}
  def resolve(id, resolution \\ "manual") do
    id |> Store.resolve(resolution, DateTime.utc_now()) |> to_entry()
  end

  @doc "Increment attempt count and update last_attempted_at for an entry."
  @spec increment_attempt(binary()) :: {:ok, term()} | {:error, term()}
  def increment_attempt(id) do
    id |> Store.increment_attempt(DateTime.utc_now()) |> to_entry()
  end

  defp insert(%{valid?: true} = changeset) do
    changeset |> apply_changes() |> Map.from_struct() |> Store.insert() |> to_entry()
  end

  defp insert(changeset), do: {:error, changeset}

  defp to_entry({:ok, fields}), do: {:ok, struct!(__MODULE__, fields)}
  defp to_entry({:error, _reason} = error), do: error
end
