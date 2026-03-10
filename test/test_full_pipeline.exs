# test_full_pipeline.exs

# Start the application to ensure Embeddings model is loaded
# This might take a moment to download/load the model if not cached
IO.puts("Starting Pincer application...")

case Application.ensure_all_started(:pincer) do
  {:ok, _} -> IO.puts("Pincer started successfully.")
  {:error, reason} -> IO.puts("Pincer start warning/error: #{inspect(reason)}")
end

# Alias modules
alias Pincer.Storage.Adapters.Postgres

IO.puts("\n1. Using Postgres storage adapter...")

# Define test data
role = "user"
content = "Why does the sun shine?"
session_id = "session_test_123"

IO.puts("\n2. Saving message (Generating Embedding + Indexing)...")
# This persists the transcript in Postgres.
case Postgres.save_message(session_id, role, content) do
  {:ok, %{id: id}} ->
    IO.puts("   [OK] Message saved with ID: #{inspect(id)}")

  {:error, e} ->
    IO.puts("   [FAIL] Save error: #{inspect(e)}")
    System.halt(1)
end

# Search
query = "sun shine"
IO.puts("\n3. Searching transcript hits...")

case Postgres.search_messages(query, 2) do
  {:ok, results} when length(results) > 0 ->
    IO.puts("   [OK] Found #{length(results)} results.")

    Enum.each(results, fn res ->
      IO.puts("     - Score: #{res.score} | Content: #{res.content}")
    end)

  {:ok, _results} ->
    IO.puts("   [FAIL] No results found.")

  {:error, reason} ->
    IO.puts("   [FAIL] Search error: #{inspect(reason)}")
end

IO.puts("\nFull pipeline test completed.")
