defmodule Pincer.Repo.Migrations.CreateGraphTables do
  use Ecto.Migration

  def change do
    create table(:nodes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:type, :string, null: false)
      add(:data, :map, null: false)
      timestamps()
    end

    create(index(:nodes, [:type]))
    create(index(:nodes, [:inserted_at]))

    create table(:edges, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:from_id, :uuid, null: false)
      add(:to_id, :uuid, null: false)
      add(:type, :string, null: false)
      timestamps()
    end

    create(index(:edges, [:from_id]))
    create(index(:edges, [:to_id]))
    create(index(:edges, [:type]))
  end
end
