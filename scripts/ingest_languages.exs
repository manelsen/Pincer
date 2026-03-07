# scripts/ingest_languages.exs
# Usage: mix run scripts/ingest_languages.exs

alias Pincer.Ports.Storage
alias Pincer.Ports.LLM
alias Pincer.Utils.CodeSkeleton

Logger.configure(level: :info)

targets = [
  %{
    name: "Gleam",
    repo: "gleam-lang/stdlib",
    branch: "main",
    base_path: "src/gleam",
    files: ["list.gleam", "result.gleam", "dict.gleam", "option.gleam", "string.gleam"],
    ext: ".gleam"
  },
  %{
    name: "Elixir",
    repo: "elixir-lang/elixir",
    branch: "main",
    base_path: "lib/elixir/lib",
    files: ["enum.ex", "list.ex", "map.ex", "keyword.ex", "stream.ex"],
    ext: ".ex"
  },
  %{
    name: "Zig",
    repo: "ziglang/zig",
    branch: "master",
    base_path: "lib/std",
    files: ["mem.zig", "array_list.zig", "fs.zig", "process.zig"],
    ext: ".zig"
  }
]

token = System.get_env("GITHUB_PERSONAL_ACCESS_TOKEN")

Enum.each(targets, fn lang ->
  IO.puts("--- Ingesting #{lang.name} ---")
  
  Enum.each(lang.files, fn file ->
    path = "#{lang.base_path}/#{file}"
    url = "https://raw.githubusercontent.com/#{lang.repo}/#{lang.branch}/#{path}"
    
    IO.write("  Fetching #{file}... ")
    
    case Req.get(url, auth: {:bearer, token}) do
      {:ok, %{status: 200, body: content}} ->
        IO.write("Done. Compressing... ")
        # Extract skeleton
        skeleton = CodeSkeleton.extract(content, lang.ext)
        
        IO.write("Vectoziring... ")
        case LLM.generate_embedding(skeleton, provider: "openrouter", model: "baai/bge-m3") do
          {:ok, vector} ->
            case Storage.index_document("Language: #{lang.name} - #{file}", skeleton, vector) do
              :ok -> IO.puts("OK!")
              error -> IO.puts("Failed Storage: #{inspect(error)}")
            end
          
          {:error, reason} ->
            IO.puts("Failed Embedding: #{inspect(reason)}")
        end

      {:ok, %{status: status}} ->
        IO.puts("Failed HTTP #{status}")

      {:error, reason} ->
        IO.puts("Failed: #{inspect(reason)}")
    end
  end)
end)

IO.puts("\n✅ Ingestion complete for Gleam, Elixir and Zig stdlibs.")
