# test_full_pipeline.exs

# Start the application to ensure Embeddings model is loaded
# This might take a moment to download/load the model if not cached
IO.puts("Starting Pincer application...")
case Application.ensure_all_started(:pincer) do
  {:ok, _} -> IO.puts("Pincer started successfully.")
  {:error,reason} -> IO.puts("Pincer start warning/error: #{inspect(reason)}")
end

# Alias modules
alias Pincer.Storage.Adapters.LanceDB

# Init LanceDB (creates directory if needed)
IO.puts("\n1. Initializing LanceDB Adapter...")
:ok = LanceDB.init()

# Define test data
role = "user"
content = "Why does the sun shine?"
session_id = "session_test_123"

IO.puts("\n2. Saving message (Generating Embedding + Indexing)...")
# This calls Embeddings.generate internally
case LanceDB.save_message(session_id, role, content) do
  {:ok, %{id: id}} -> 
    IO.puts("   [OK] Message saved with ID: #{id}")
  
  {:error, e} -> 
    IO.puts("   [FAIL] Save error: #{inspect(e)}")
    System.halt(1)
end

# Search
query = "sunlight energy"
IO.puts("\n3. Searching for similar messages...")
results = LanceDB.search_similar_messages(query, 2)

if length(results) > 0 do
  IO.puts("   [OK] Found #{length(results)} results.")
  Enum.each(results, fn res ->
    IO.puts("     - Score: #{res.score} | Content: #{res.content}")
  end)
else
  IO.puts("   [FAIL] No results found.")
end

IO.puts("\nFull pipeline test completed.")
