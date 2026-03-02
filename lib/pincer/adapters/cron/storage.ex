defmodule Pincer.Adapters.Cron.Storage do
  @moduledoc """
  Database context for managing persistent cron job schedules.

  Storage provides the persistence layer for `Pincer.Adapters.Cron.Job` records,
  handling CRUD operations and schedule calculations. All jobs are stored
  in the database and survive application restarts.

  ## Responsibilities

    - Querying due jobs for the Scheduler
    - Calculating next execution times using cron expressions
    - Creating, enabling, disabling, and deleting jobs
    - Converting between DateTime and NaiveDateTime formats

  ## Usage with Scheduler

  The `Pincer.Adapters.Cron.Scheduler` calls `list_due_jobs/1` every 60 seconds:

      due_jobs = Pincer.Adapters.Cron.Storage.list_due_jobs()
      # => [%Job{id: "...", prompt: "Wake up!", ...}]

  ## Job Lifecycle

      # 1. Create a job (automatically sets next_run_at)
      {:ok, job} = Storage.create_job(%{
        name: "Daily Reminder",
        cron_expression: "0 9 * * *",
        prompt: "Good morning!",
        session_id: "telegram:123"
      })

      # 2. Job is picked up by Scheduler when due
      # 3. Scheduler calls update_next_run!/1 after execution
      # 4. To temporarily stop: disable_job/1
      # 5. To permanently remove: delete_job/1

  ## Examples

      # List all jobs (for admin/debugging)
      jobs = Pincer.Adapters.Cron.Storage.list_jobs()

      # Disable a job temporarily
      {:ok, _} = Pincer.Adapters.Cron.Storage.disable_job(job_id)

      # Delete permanently
      {:ok, _} = Pincer.Adapters.Cron.Storage.delete_job(job_id)
  """
  import Ecto.Query
  alias Pincer.Infra.Repo
  alias Pincer.Adapters.Cron.Job

  @doc """
  Returns all enabled jobs whose `next_run_at` is at or before the given time.

  This is the primary query used by `Pincer.Adapters.Cron.Scheduler` to find jobs
  that need to be executed.

  ## Parameters

    - `now` - Reference datetime (defaults to `DateTime.utc_now/0`)

  ## Returns

    - `list(Job.t())` - List of due jobs, may be empty

  ## Examples

      # Get jobs due right now
      due = Pincer.Adapters.Cron.Storage.list_due_jobs()
      # => [%Job{name: "Morning Alert", ...}]

      # Get jobs due as of a specific time
      cutoff = ~U[2024-01-15 10:00:00Z]
      due = Pincer.Adapters.Cron.Storage.list_due_jobs(cutoff)

      # No jobs due yet
      [] = Pincer.Adapters.Cron.Storage.list_due_jobs()
  """
  @spec list_due_jobs(DateTime.t()) :: [Job.t()]
  def list_due_jobs(now \\ DateTime.utc_now()) do
    Job
    |> where([j], j.enabled == true and j.next_run_at <= ^now)
    |> Repo.all()
  end

  @doc """
  Calculates and updates the `next_run_at` timestamp for a job.

  Parses the job's cron expression and computes the next execution time
  using `Crontab.Scheduler`. Handles edge cases like impossible dates
  (e.g., February 30th) by disabling the job.

  ## Parameters

    - `job` - The `Job` struct to update

  ## Returns

    - `Job.t()` - The updated job with new `next_run_at`
    - `Job.t()` - The job with `enabled: false` if no future runs exist

  ## Raises

    - Raises if cron expression is invalid (should not happen if validated)

  ## Examples

      job = %Job{cron_expression: "0 9 * * *", ...}
      updated = Pincer.Adapters.Cron.Storage.update_next_run!(job)
      # => %Job{next_run_at: ~U[2024-01-16 09:00:00Z], ...}
  """
  @spec update_next_run!(Job.t()) :: Job.t()
  def update_next_run!(%Job{} = job) do
    {:ok, expr} = Crontab.CronExpression.Parser.parse(job.cron_expression)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Crontab.Scheduler.get_next_run_date(expr, now) do
      {:ok, next_date} ->
        utc_next_date =
          case next_date do
            %NaiveDateTime{} -> DateTime.from_naive!(next_date, "Etc/UTC")
            %DateTime{} -> next_date
          end

        job
        |> Job.changeset(%{next_run_at: utc_next_date})
        |> Repo.update!()

      {:error, _} ->
        job
        |> Job.changeset(%{enabled: false})
        |> Repo.update!()
    end
  end

  @doc """
  Creates a new cron job and calculates its first `next_run_at`.

  The job is inserted into the database and immediately updated with
  its first scheduled execution time based on the cron expression.

  ## Parameters

    - `attrs` - Map with required keys: `:name`, `:cron_expression`, `:prompt`, `:session_id`

  ## Returns

    - `{:ok, job}` - Successfully created job with `next_run_at` set
    - `{:error, changeset}` - Validation failed (see `Job.changeset/2` for errors)

  ## Examples

      {:ok, job} = Pincer.Adapters.Cron.Storage.create_job(%{
        name: "Weekly Report",
        cron_expression: "0 9 * * 1",
        prompt: "Generate weekly report",
        session_id: "cli:admin"
      })
      # => {:ok, %Job{id: "uuid-...", next_run_at: ~U[2024-01-22 09:00:00Z]}}

      {:error, changeset} = Pincer.Adapters.Cron.Storage.create_job(%{name: "Bad"})
      # => {:error, %Ecto.Changeset{errors: [cron_expression: {"can't be blank", ...}, ...]}}
  """
  @spec create_job(map()) :: {:ok, Job.t()} | {:error, Ecto.Changeset.t()}
  def create_job(attrs) do
    %Job{}
    |> Job.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, job} ->
        {:ok, update_next_run!(job)}

      error ->
        error
    end
  end

  @doc """
  Disables a job, preventing it from being picked up by `list_due_jobs/1`.

  The job remains in the database but is excluded from scheduling queries.
  Use this for temporarily pausing a job without deleting it.

  ## Parameters

    - `id` - The job's UUID (binary or string representation)

  ## Returns

    - `{:ok, job}` - Successfully disabled job
    - `{:error, :not_found}` - No job exists with the given ID

  ## Examples

      {:ok, job} = Pincer.Adapters.Cron.Storage.disable_job("uuid-123")
      # => {:ok, %Job{enabled: false, ...}}

      {:error, :not_found} = Pincer.Adapters.Cron.Storage.disable_job("nonexistent")
  """
  @spec disable_job(binary()) :: {:ok, Job.t()} | {:error, :not_found}
  def disable_job(id) do
    case Repo.get(Job, id) do
      nil ->
        {:error, :not_found}

      job ->
        job
        |> Job.changeset(%{enabled: false})
        |> Repo.update()
    end
  end

  @doc """
  Returns all cron jobs in the database, regardless of status.

  Useful for administrative interfaces and debugging.

  ## Returns

    - `list(Job.t())` - All jobs, may be empty

  ## Examples

      jobs = Pincer.Adapters.Cron.Storage.list_jobs()
      # => [%Job{name: "Job 1"}, %Job{name: "Job 2"}]

      active = Enum.filter(jobs, & &1.enabled)
      disabled = Enum.reject(jobs, & &1.enabled)
  """
  @spec list_jobs() :: [Job.t()]
  def list_jobs do
    Repo.all(Job)
  end

  @doc """
  Permanently deletes a job from the database.

  This action is irreversible. For temporary suspension, use `disable_job/1`.

  ## Parameters

    - `id` - The job's UUID (binary or string representation)

  ## Returns

    - `{:ok, job}` - Successfully deleted job (returned before deletion)
    - `{:error, :not_found}` - No job exists with the given ID

  ## Examples

      {:ok, job} = Pincer.Adapters.Cron.Storage.delete_job("uuid-123")
      # => {:ok, %Job{name: "Deleted Job", ...}}

      {:error, :not_found} = Pincer.Adapters.Cron.Storage.delete_job("nonexistent")
  """
  @spec delete_job(binary()) :: {:ok, Job.t()} | {:error, :not_found}
  def delete_job(id) do
    case Repo.get(Job, id) do
      nil -> {:error, :not_found}
      job -> Repo.delete(job)
    end
  end
end
