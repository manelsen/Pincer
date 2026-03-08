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

    Mix.shell().info("[PURGE] Identifying invalid document indices in 'tmp/' and 'workspaces/'...")

    query =
      from(n in Node,
        where:
          n.type == "document" and
            (fragment("json_extract(data, '$.path') LIKE ?", "tmp/%") or
               fragment("json_extract(data, '$.path') LIKE ?", "workspaces/%"))
      )

    {count, _} = Repo.delete_all(query)

    if count > 0 do
      Mix.shell().info("[PURGE] Successfully deleted #{count} invalid indices.")
    else
      Mix.shell().info("[PURGE] No invalid indices found. Knowledge graph is clean.")
    end
  end
end
