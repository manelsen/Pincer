defmodule Mix.Tasks.Pincer.PurgeIndices do
  @moduledoc """
  Purges invalid document indices from the knowledge graph via `Pincer.Ports.Storage`.
  Specifically, it removes any `'document'` nodes whose path starts with `'tmp/'` or `'workspaces/'`.
  """
  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  alias Pincer.Ports.Storage

  @default_prefixes ["tmp/", "workspaces/"]
  @shortdoc "Purges invalid indices (tmp/ and workspaces/) from the knowledge graph"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info(
      "[PURGE] Identifying invalid document indices in 'tmp/' and 'workspaces/'..."
    )

    case purge() do
      {:ok, count} when count > 0 ->
        Mix.shell().info("[PURGE] Successfully deleted #{count} invalid indices.")

      {:ok, _count} ->
        Mix.shell().info("[PURGE] No invalid indices found. Knowledge graph is clean.")

      {:error, reason} ->
        Mix.raise("[PURGE] Failed to purge invalid indices: #{inspect(reason)}")
    end
  end

  @doc false
  @spec purge(module(), [String.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def purge(storage \\ Storage, prefixes \\ @default_prefixes) do
    storage.purge_invalid_documents(prefixes)
  end
end
