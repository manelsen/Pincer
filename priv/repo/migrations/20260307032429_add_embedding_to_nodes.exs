defmodule Pincer.Repo.Migrations.AddEmbeddingToNodes do
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      add :embedding, :binary
    end
  end
end
