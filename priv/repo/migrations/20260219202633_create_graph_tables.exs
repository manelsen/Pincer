defmodule Pincer.Repo.Migrations.CreateGraphTables do
  use Ecto.Migration

  def change do
    create table(:nodes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :type, :string # bug, fix, file
      add :data, :map
      timestamps()
    end

    create index(:nodes, [:type])

    create table(:edges, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :from_id, :uuid
      add :to_id, :uuid
      add :type, :string # occurs_in, solves
      timestamps()
    end

    create index(:edges, [:from_id])
    create index(:edges, [:to_id])
    create index(:edges, [:type])
  end
end
