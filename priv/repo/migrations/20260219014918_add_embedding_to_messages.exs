defmodule Pincer.Repo.Migrations.AddEmbeddingToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :embedding, :binary
    end
  end
end
