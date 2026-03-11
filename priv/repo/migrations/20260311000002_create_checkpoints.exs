defmodule Pincer.Infra.Repo.Migrations.CreateCheckpoints do
  use Ecto.Migration

  def change do
    create table(:checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :string, null: false
      add :task_id, :string, null: true
      add :project_id, :binary_id, null: true
      add :status, :string, null: false, default: "running"
      add :history_snapshot, :binary, null: false
      add :step_count, :integer, default: 0
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create index(:checkpoints, [:session_id])
    create index(:checkpoints, [:task_id])
  end
end
