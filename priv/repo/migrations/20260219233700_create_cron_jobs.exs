defmodule Pincer.Repo.Migrations.CreateCronJobs do
  use Ecto.Migration

  def change do
    create table(:cron_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :cron_expression, :string, null: false
      add :prompt, :text, null: false
      add :session_id, :string, null: false
      add :next_run_at, :utc_datetime_usec
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cron_jobs, [:next_run_at])
    create index(:cron_jobs, [:enabled])
  end
end
