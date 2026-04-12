defmodule Pincer.Core.Project.HordeSupervisor do
  @moduledoc """
  Cluster-wide dynamic supervisor for project processes, backed by Horde.
  """

  use Horde.DynamicSupervisor

  def start_link(opts \\ []) do
    Horde.DynamicSupervisor.start_link(__MODULE__, opts,
      name: __MODULE__,
      distribution_strategy: Horde.UniformDistribution
    )
  end

  @impl true
  def init(opts) do
    Horde.DynamicSupervisor.init(
      Keyword.merge([strategy: :one_for_one, distribution_strategy: Horde.UniformDistribution],
        opts
      )
    )
  end

  @doc "Start a project process cluster-wide."
  @spec start_project(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_project(args) do
    Horde.DynamicSupervisor.start_child(__MODULE__, {Pincer.Core.Project.Server, args})
  end
end
