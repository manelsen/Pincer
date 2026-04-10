defmodule Pincer.Repo.Migrations.AddHnswIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Default embedding model is baai/bge-m3 (via OpenRouter), which outputs 1024-dimensional vectors.
  # HNSW indexes require fixed-dimension columns. We alter the columns to pin the dimension
  # before creating the indexes. This is safe because all stored vectors are already 1024-dim.
  @dims 1024

  def up do
    execute "ALTER TABLE messages ALTER COLUMN embedding TYPE vector(#{@dims})"
    execute "ALTER TABLE nodes ALTER COLUMN embedding TYPE vector(#{@dims})"

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_messages_embedding_hnsw
    ON messages
    USING hnsw (embedding vector_cosine_ops)
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_nodes_embedding_hnsw
    ON nodes
    USING hnsw (embedding vector_cosine_ops)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS idx_messages_embedding_hnsw"
    execute "DROP INDEX IF EXISTS idx_nodes_embedding_hnsw"

    execute "ALTER TABLE messages ALTER COLUMN embedding TYPE vector"
    execute "ALTER TABLE nodes ALTER COLUMN embedding TYPE vector"
  end
end
