defmodule Pincer.Infra.Repo.Migrations.AddMemoryTrackingToNodes do
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      add :importance_score, :float, default: 0.5, null: false
      add :access_count, :integer, default: 0, null: false
      add :last_accessed_at, :utc_datetime, null: true
    end
  end
end
