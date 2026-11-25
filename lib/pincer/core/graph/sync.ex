defmodule Pincer.Core.Graph.Sync do
  @moduledoc """
  Logic for synchronizing the knowledge graph with the local filesystem and Git.
  """
  require Logger
  alias Pincer.Ports.Git
  alias Pincer.Ports.Storage
  alias Pincer.Ports.LLM
  alias Pincer.Utils.CodeSkeleton

  @doc """
  Performs an incremental sync using Git within a specific workspace.
  """
  @spec sync_git(String.t()) :: Git.file_result()
  def sync_git(workspace_root), do: sync_using_git(workspace_root, :changed)

  @doc """
  Performs a full sync of all supported files in the workspace.
  """
  @spec sync_full(String.t()) :: Git.file_result()
  def sync_full(workspace_root), do: sync_using_git(workspace_root, :tracked)

  defp sync_using_git(workspace_root, query) do
    case Git.files(workspace_root, query) do
      {:ok, git_paths} ->
        files = Enum.filter(git_paths, &supported_file?/1)
        Logger.info("[GRAPH-SYNC] Indexing #{length(files)} #{query} files in #{workspace_root}.")

        Enum.each(files, fn rel_path ->
          index_file(Path.expand(rel_path, workspace_root), workspace_root)
        end)

        {:ok, files}

      {:error, :not_a_repository} ->
        sync_without_git(workspace_root, query)

      {:error, reason} = error ->
        Logger.warning("[GRAPH-SYNC] Git sync failed in #{workspace_root}: #{reason}")
        error
    end
  end

  defp sync_without_git(workspace_root, :tracked) do
    Logger.debug("[GRAPH-SYNC] No Git at #{workspace_root}. Performing recursive scan...")
    scan_and_index(workspace_root, workspace_root)
    {:ok, []}
  end

  defp sync_without_git(workspace_root, :changed) do
    Logger.debug(
      "[GRAPH-SYNC] Not a Git repository at #{workspace_root}. Skipping incremental sync."
    )

    {:ok, []}
  end

  defp scan_and_index(path, workspace_root) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          abs_path = Path.join(path, entry)

          if File.dir?(abs_path) do
            if supported_dir?(abs_path), do: scan_and_index(abs_path, workspace_root)
          else
            index_file(abs_path, workspace_root)
          end
        end)

      _ ->
        :ok
    end
  end

  @doc """
  Indexes a single file into the knowledge graph with vector embeddings.
  Uses skeleton hashing to avoid redundant API calls.
  """
  def index_file(abs_path, workspace_root) do
    rel_path = Path.relative_to(abs_path, workspace_root)

    if File.exists?(abs_path) and supported_file?(rel_path) do
      try do
        content = File.read!(abs_path)
        ext = Path.extname(abs_path)
        skeleton = CodeSkeleton.extract(content, ext)
        skeleton_hash = :crypto.hash(:sha256, skeleton) |> Base.encode16()

        # Optimization: Only re-index if the skeleton has changed
        existing_meta = Storage.get_document_metadata(rel_path, workspace_root)

        if needs_indexing?(existing_meta, skeleton_hash) do
          # We index the skeleton because it provides the best architecture mapping
          # using the least amount of space/tokens.
          case LLM.generate_embedding(skeleton, provider: "openrouter") do
            {:ok, vector} ->
              metadata = %{
                "workspace_root" => workspace_root,
                "skeleton_hash" => skeleton_hash,
                "indexed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
              }

              Storage.index_document(rel_path, skeleton, vector, metadata)
              Logger.debug("[GRAPH-SYNC] Indexed [#{workspace_root}]: #{rel_path}")

            error ->
              Logger.error(
                "[GRAPH-SYNC] Failed to generate embedding for #{rel_path}: #{inspect(error)}"
              )
          end
        else
          Logger.debug("[GRAPH-SYNC] Skipping redundant index (unchanged skeleton): #{rel_path}")
        end
      rescue
        e -> Logger.error("[GRAPH-SYNC] Failed to index #{rel_path}: #{inspect(e)}")
      end
    end
  end

  defp needs_indexing?(nil, _hash), do: true

  defp needs_indexing?(metadata, current_hash) do
    # Re-index if hash changed OR if record is older than 24h (safety refresh)
    stored_hash = metadata["skeleton_hash"]
    indexed_at = metadata["indexed_at"]

    cond do
      stored_hash != current_hash ->
        true

      is_nil(indexed_at) ->
        true

      true ->
        # Optional: check age
        case DateTime.from_iso8601(indexed_at) do
          {:ok, dt, _} ->
            DateTime.diff(DateTime.utc_now(), dt, :hour) > 24

          _ ->
            true
        end
    end
  end

  defp supported_file?(path) do
    ext = Path.extname(path) |> String.downcase()

    is_supported_ext =
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
      ]

    # Special handling for session logs: only index if they are in the current session
    # and don't index them if they are too frequent (avoiding self-reference loops)
    is_session_log = String.contains?(path, "/sessions/session_")

    is_supported_ext and not dir_ignored?(path) and not is_session_log
  end

  defp supported_dir?(path) do
    not dir_ignored?(path)
  end

  defp dir_ignored?(path) do
    String.starts_with?(path, "tmp/") or
      String.starts_with?(path, "workspaces/") or
      String.starts_with?(path, ".npm/") or
      String.contains?(path, "/node_modules/") or
      String.contains?(path, "/deps/") or
      String.contains?(path, "/_build/") or
      String.contains?(path, "/.git/")
  end
end
