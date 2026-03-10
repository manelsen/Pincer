defmodule Pincer.Repo.Migrations.AddEmbeddingToMessages do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector")

    alter table(:messages) do
      add(:embedding, :vector)
    end
  end
end
