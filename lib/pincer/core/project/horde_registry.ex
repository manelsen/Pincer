defmodule Pincer.Core.Project.HordeRegistry do
  @moduledoc """
  Cluster-wide process registry for projects, backed by Horde.
  """

  use Horde.Registry

  def start_link(opts \\ []) do
    Horde.Registry.start_link(__MODULE__, Keyword.merge([keys: :unique], opts), name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Horde.Registry.init(opts)
  end

  @doc "Returns a `{:via, ...}` tuple for use with `GenServer.start_link/3`."
  @spec via_tuple(String.t()) :: {:via, Horde.Registry, {__MODULE__, String.t()}}
  def via_tuple(project_id) do
    {:via, Horde.Registry, {__MODULE__, project_id}}
  end
end
