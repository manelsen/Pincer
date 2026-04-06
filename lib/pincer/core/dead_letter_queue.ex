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
  import Ecto.Query

  require Logger

  alias Pincer.Infra.Repo

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

    %__MODULE__{}
    |> changeset(params)
    |> Repo.insert()
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
    query =
      from(d in __MODULE__,
        where: is_nil(d.resolved_at),
        order_by: [asc: d.inserted_at]
      )

    query =
      if operation_type do
        where(query, [d], d.operation_type == ^operation_type)
      else
        query
      end

    Repo.all(query)
  end

  @doc "Mark a DLQ entry as resolved."
  @spec resolve(binary(), String.t()) :: {:ok, term()} | {:error, term()}
  def resolve(id, resolution \\ "manual") do
    case Repo.get(__MODULE__, id) do
      nil ->
        {:error, :not_found}

      entry ->
        entry
        |> changeset(%{resolved_at: DateTime.utc_now(), resolution: resolution})
        |> Repo.update()
    end
  end

  @doc "Increment attempt count and update last_attempted_at for an entry."
  @spec increment_attempt(binary()) :: {:ok, term()} | {:error, term()}
  def increment_attempt(id) do
    case Repo.get(__MODULE__, id) do
      nil ->
        {:error, :not_found}

      entry ->
        entry
        |> changeset(%{
          attempt_count: entry.attempt_count + 1,
          last_attempted_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end
end
