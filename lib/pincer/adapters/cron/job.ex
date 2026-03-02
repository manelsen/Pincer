defmodule Pincer.Adapters.Cron.Job do
  @moduledoc """
  Ecto schema representing a scheduled cron job in Pincer.

  A Job encapsulates a prompt that should be sent to a specific session
  at recurring intervals defined by a cron expression. Jobs persist across
  application restarts and are managed by `Pincer.Adapters.Cron.Scheduler`.

  ## Fields

  | Field | Type | Description |
  |-------|------|-------------|
  | `id` | `binary_id` | Unique identifier (UUID) |
  | `name` | `string` | Human-readable job name |
  | `cron_expression` | `string` | Standard 5-field cron expression |
  | `prompt` | `string` | The prompt to send when triggered |
  | `session_id` | `string` | Target session identifier (e.g., `"telegram:12345"`) |
  | `next_run_at` | `utc_datetime_usec` | Next scheduled execution time |
  | `enabled` | `boolean` | Whether the job is active (default: `true`) |

  ## Cron Expression Format

  Uses standard 5-field cron syntax (minute, hour, day of month, month, day of week):

      "0 8 * * *"     # Every day at 8:00 AM UTC
      "*/15 * * * *"  # Every 15 minutes
      "0 9 * * 1-5"   # Weekdays at 9:00 AM UTC
      "0 0 1 * *"     # First day of every month at midnight

  ## Examples

      # Creating a new job struct
      %Pincer.Adapters.Cron.Job{
        name: "Daily Standup Reminder",
        cron_expression: "0 9 * * 1-5",
        prompt: "Time for daily standup!",
        session_id: "telegram:123456789",
        enabled: true
      }

      # Using changeset for validation
      attrs = %{
        name: "Hourly Check",
        cron_expression: "0 * * * *",
        prompt: "Check system status",
        session_id: "cli:admin"
      }

      changeset = Pincer.Adapters.Cron.Job.changeset(%Pincer.Adapters.Cron.Job{}, attrs)
      # => %Ecto.Changeset{valid?: true, ...}

      # Invalid cron expression
      invalid_attrs = %{cron_expression: "invalid"}
      changeset = Pincer.Adapters.Cron.Job.changeset(%Pincer.Adapters.Cron.Job{}, invalid_attrs)
      # => %Ecto.Changeset{valid?: false, errors: [cron_expression: {"invalid cron format...", ...}]}
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: binary() | nil,
          name: String.t() | nil,
          cron_expression: String.t() | nil,
          prompt: String.t() | nil,
          session_id: String.t() | nil,
          next_run_at: DateTime.t() | nil,
          enabled: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "cron_jobs" do
    field(:name, :string)
    field(:cron_expression, :string)
    field(:prompt, :string)
    field(:session_id, :string)
    field(:next_run_at, :utc_datetime_usec)
    field(:enabled, :boolean, default: true)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for validating and casting job attributes.

  ## Required Fields

    - `:name` - Human-readable identifier for the job
    - `:cron_expression` - Valid 5-field cron expression
    - `:prompt` - The text prompt to send when triggered
    - `:session_id` - Target session for the prompt

  ## Optional Fields

    - `:next_run_at` - Automatically set by `Storage.create_job/1`
    - `:enabled` - Defaults to `true`

  ## Validation

    - Validates presence of required fields
    - Validates cron expression syntax using `Crontab.CronExpression.Parser`

  ## Examples

      iex> Pincer.Adapters.Cron.Job.changeset(%Pincer.Adapters.Cron.Job{}, %{
      ...>   name: "Test Job",
      ...>   cron_expression: "0 8 * * *",
      ...>   prompt: "Good morning!",
      ...>   session_id: "test:123"
      ...> })
      %Ecto.Changeset{valid?: true}

      iex> Pincer.Adapters.Cron.Job.changeset(%Pincer.Adapters.Cron.Job{}, %{cron_expression: "bad"})
      %Ecto.Changeset{valid?: false}
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(job, attrs) do
    job
    |> cast(attrs, [:name, :cron_expression, :prompt, :session_id, :next_run_at, :enabled])
    |> validate_required([:name, :cron_expression, :prompt, :session_id])
    |> validate_cron_expression()
  end

  defp validate_cron_expression(changeset) do
    case get_change(changeset, :cron_expression) do
      nil ->
        changeset

      expr ->
        case Crontab.CronExpression.Parser.parse(expr) do
          {:ok, _} ->
            changeset

          {:error, _} ->
            add_error(
              changeset,
              :cron_expression,
              "invalid cron format. Valid example: '0 8 * * *'"
            )
        end
    end
  end
end
