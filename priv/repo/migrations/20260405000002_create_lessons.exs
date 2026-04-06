defmodule Pincer.Infra.Repo.Migrations.CreateLessons do
  use Ecto.Migration

  def change do
    create table(:lessons, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, :string, null: false
      add :content, :text, null: false
      add :source, :string, null: false, default: "reflection"
      add :confidence, :float, null: false, default: 0.5
      add :extraction_confidence, :float, null: false, default: 0.5
      add :success_count, :integer, default: 0
      add :failure_count, :integer, default: 0
      add :contradiction_penalty, :float, default: 0.0
      add :active, :boolean, default: true
      add :last_applied_at, :utc_datetime
      add :last_outcome, :string
      add :meta, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create index(:lessons, [:agent_id])
    create index(:lessons, [:agent_id, :confidence])
    create index(:lessons, [:agent_id, :active])
  end
end
