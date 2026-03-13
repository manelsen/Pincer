defmodule Mix.Tasks.Pincer.FullSync do
  @moduledoc """
  Performs a full synchronization of the knowledge graph.
  It indexes all supported files in the repository using Git ls-files.
  """
  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  @shortdoc "Indexes the entire project into the knowledge graph"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("[FULL-SYNC] Starting full repository indexing...")

    case Pincer.Core.Graph.Sync.sync_full(File.cwd!()) do
      {:ok, files} ->
        Mix.shell().info("[FULL-SYNC] Successfully indexed #{length(files)} files.")

      {:error, reason} ->
        Mix.shell().error("[FULL-SYNC] Failed: #{inspect(reason)}")
    end
  end
end
