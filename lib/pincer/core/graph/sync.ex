defmodule Pincer.Core.Graph.Sync do
  @moduledoc """
  Logic for synchronizing the knowledge graph with the local filesystem and Git.
  """
  require Logger
  alias Pincer.Ports.Storage
  alias Pincer.Ports.LLM
  alias Pincer.Utils.CodeSkeleton

  @doc """
  Performs an incremental sync using Git.
  """
  def sync_git do
    # 1. Get changed files since last commit or current index
    # For now, let's just get the changed files in the working tree.
    case System.cmd("git", ["diff", "--name-only", "HEAD"]) do
      {output, 0} ->
        files = output |> String.split("\n", trim: true) |> Enum.filter(&supported_file?/1)
        Logger.info("[GRAPH-SYNC] Git detected #{length(files)} changed files. Syncing...")

        Enum.each(files, &index_file/1)
        {:ok, files}

      _ ->
        {:error, :git_failed}
    end
  end

  @doc """
  Indexes a single file into the knowledge graph with vector embeddings.
  """
  def index_file(path) do
    if File.exists?(path) and supported_file?(path) do
      try do
        content = File.read!(path)
        ext = Path.extname(path)
        skeleton = CodeSkeleton.extract(content, ext)

        # We index the skeleton because it provides the best architecture mapping
        # using the least amount of space/tokens.
        case LLM.generate_embedding(skeleton, provider: "openrouter") do
          {:ok, vector} ->
            Storage.index_document(path, skeleton, vector)
            Logger.debug("[GRAPH-SYNC] Indexed skeleton: #{path}")

          error ->
            Logger.error(
              "[GRAPH-SYNC] Failed to generate embedding for #{path}: #{inspect(error)}"
            )
        end
      rescue
        e -> Logger.error("[GRAPH-SYNC] Failed to index #{path}: #{inspect(e)}")
      end
    end
  end

  defp supported_file?(path) do
    ext = Path.extname(path) |> String.downcase()

    ext in [
      ".ex",
      ".exs",
      ".ts",
      ".js",
      ".py",
      ".md",
      ".txt",
      ".go",
      ".rs",
      ".java",
      ".c",
      ".cpp"
    ] and
      not String.contains?(path, "/deps/") and
      not String.contains?(path, "/_build/") and
      not String.contains?(path, "/.git/")
  end
end
