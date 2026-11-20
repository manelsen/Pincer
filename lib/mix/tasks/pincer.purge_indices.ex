defmodule Mix.Tasks.Pincer.PurgeIndices do
  @moduledoc """
  Purges invalid document indices from the knowledge graph.
  Specifically, it removes any 'document' nodes whose path starts with 'tmp/' or 'workspaces/'.
  """
  use Mix.Task
  use Boundary, classify_to: Pincer.Mix
  import Ecto.Query
  alias Pincer.Infra.Repo
  alias Pincer.Storage.Graph.Node

  @shortdoc "Purges invalid indices (tmp/ and workspaces/) from the knowledge graph"

  @impl Mix.Task
  def run(_args) do
    # Ensure the application and Repo are started
    Mix.Task.run("app.start")

    Mix.shell().info(
      "[PURGE] Identifying invalid document indices in 'tmp/' and 'workspaces/'..."
    )

    {count, _} = purge()

    if count > 0 do
      Mix.shell().info("[PURGE] Successfully deleted #{count} invalid indices.")
    else
      Mix.shell().info("[PURGE] No invalid indices found. Knowledge graph is clean.")
    end
  end

  @doc false
  @spec invalid_documents_query() :: Ecto.Query.t()
  def invalid_documents_query do
    from(n in Node,
      where:
        n.type == "document" and
          (fragment("?->>'path' LIKE ?", n.data, "tmp/%") or
             fragment("?->>'path' LIKE ?", n.data, "workspaces/%"))
    )
  end

  @doc false
  @spec purge(module()) :: {non_neg_integer(), nil | [term()]}
  def purge(repo \\ Repo) do
    repo.delete_all(invalid_documents_query())
  end
end
