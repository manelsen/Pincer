defmodule Pincer.Ports.Git do
  @moduledoc "Local Git operations used by project workflows and graph indexing."

  @type branch_result ::
          {:ok,
           %{
             name: String.t(),
             status: :created | :existing,
             source_branch: String.t(),
             repo_path: String.t(),
             bootstrapped: boolean()
           }}
          | {:error, term()}

  @type file_query :: :changed | :tracked
  @type file_result :: {:ok, [String.t()]} | {:error, :not_a_repository | :git_failed | :enoent}

  @callback ensure_branch(String.t(), keyword()) :: branch_result()
  @callback files(String.t(), file_query()) :: file_result()

  @doc "Ensures a project branch exists in the workspace or an isolated local repository."
  @spec ensure_branch(String.t(), keyword()) :: branch_result()
  def ensure_branch(name, opts \\ []), do: adapter().ensure_branch(name, opts)

  @doc "Lists changed or tracked paths relative to the given repository."
  @spec files(String.t(), file_query()) :: file_result()
  def files(workspace, query), do: adapter().files(workspace, query)

  defp adapter, do: Application.fetch_env!(:pincer, :git_adapter)
end
