defmodule Pincer.Storage.Checkpoint do
  @moduledoc """
  Plain struct for task checkpoints.

  A checkpoint captures the execution state of an agent session at a
  given point in time so that it can be resumed after a restart or
  failure.

  ## Status values

  | Status | Meaning |
  |--------|---------|
  | `"running"` | Active — the session is currently executing |
  | `"paused"` | Suspended — can be resumed |
  | `"finished"` | Finished successfully (used by Sub-Agents) |
  | `"failed"` | Terminated with an error |
  | `"interrupted"` | Running in a previous VM boot and now stale |
  | `"completed"` | Finished successfully |

  ## Schema

  | Field | Type | Description |
  |-------|------|-------------|
  | `id` | `binary_id` | UUID primary key (auto-generated) |
  | `session_id` | `string` | Owning session identifier |
  | `task_id` | `string` | Optional task identifier |
  | `project_id` | `binary_id` | Optional project reference |
  | `status` | `string` | Execution status (see above) |
  | `history_snapshot` | `binary` | Serialised conversation history |
  | `step_count` | `integer` | Number of steps executed so far |
  | `metadata` | `map` | Arbitrary key-value annotations |
  | `inserted_at` | `utc_datetime` | Creation timestamp |
  | `updated_at` | `utc_datetime` | Last update timestamp |

  ## Examples

      iex> Pincer.Storage.Checkpoint.changeset(
      ...>   %Pincer.Storage.Checkpoint{},
      ...>   %{
      ...>     session_id: "sess-1",
      ...>     status: "running",
      ...>     history_snapshot: :erlang.term_to_binary([])
      ...>   }
      ...> )
      %Pincer.Utils.Validation{valid?: true, ...}

  """

  import Pincer.Utils.Validation

  @valid_statuses ~w(running paused failed finished interrupted completed)

  defstruct id: nil,
            session_id: nil,
            task_id: nil,
            project_id: nil,
            status: "running",
            history_snapshot: nil,
            step_count: 0,
            metadata: %{},
            inserted_at: nil,
            updated_at: nil

  @doc """
  Returns the canonical list of checkpoint statuses accepted by the schema.

  Storage adapters use this single list when validating `load_checkpoint/2`
  status filters, so the accepted vocabulary cannot drift.
  """
  @spec valid_statuses() :: [String.t()]
  def valid_statuses, do: @valid_statuses

  @type t :: %__MODULE__{
          id: binary() | nil,
          session_id: String.t(),
          task_id: String.t() | nil,
          project_id: binary() | nil,
          status: String.t(),
          history_snapshot: binary(),
          step_count: non_neg_integer(),
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Creates a changeset for validating and casting checkpoint attributes.

  ## Required Fields

    - `session_id` - The owning session
    - `status` - One of `"running"`, `"paused"`, `"failed"`, `"finished"`,
      `"interrupted"`, `"completed"`
    - `history_snapshot` - Binary blob of the serialised history

  ## Examples

      iex> Pincer.Storage.Checkpoint.changeset(
      ...>   %Pincer.Storage.Checkpoint{},
      ...>   %{session_id: "s1", status: "invalid", history_snapshot: <<>>}
      ...> )
      %Pincer.Utils.Validation{valid?: false, errors: [status: {"is invalid", ...}]}

  """
  @spec changeset(t(), map()) :: Pincer.Utils.Validation.t()
  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, [
      :session_id,
      :task_id,
      :project_id,
      :status,
      :history_snapshot,
      :step_count,
      :metadata
    ])
    |> validate_required([:session_id, :status, :history_snapshot])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:step_count, greater_than_or_equal_to: 0)
  end
end
