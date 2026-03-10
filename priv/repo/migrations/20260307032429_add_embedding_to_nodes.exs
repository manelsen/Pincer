defmodule Pincer.Repo.Migrations.AddEmbeddingToNodes do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector")

    alter table(:nodes) do
      add(:embedding, :vector)
    end

    execute("""
    CREATE INDEX nodes_document_content_fts_idx
    ON nodes
    USING GIN (to_tsvector('simple', COALESCE(data->>'content', '')))
    WHERE type = 'document'
    """)

    execute("""
    CREATE INDEX nodes_document_path_idx
    ON nodes ((data->>'path'))
    WHERE type = 'document'
    """)

    execute("""
    CREATE INDEX nodes_document_session_id_idx
    ON nodes ((data->>'session_id'))
    WHERE type = 'document'
    """)

    execute("""
    CREATE INDEX nodes_document_memory_type_idx
    ON nodes ((data->>'memory_type'))
    WHERE type = 'document'
    """)
  end
end
