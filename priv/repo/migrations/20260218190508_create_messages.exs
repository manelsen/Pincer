defmodule Pincer.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add(:session_id, :string, null: false)
      add(:role, :string, null: false)
      add(:content, :text, null: false)

      timestamps()
    end

    create(index(:messages, [:session_id]))

    execute("""
    CREATE INDEX messages_content_fts_idx
    ON messages
    USING GIN (to_tsvector('simple', COALESCE(content, '')))
    """)
  end
end
