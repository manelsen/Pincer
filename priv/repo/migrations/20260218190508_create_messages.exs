defmodule Pincer.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :session_id, :string
      add :role, :string
      add :content, :text

      timestamps()
    end

    create index(:messages, [:session_id])
  end
end
