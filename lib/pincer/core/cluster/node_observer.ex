defmodule Pincer.Core.Cluster.NodeObserver do
  @moduledoc """
  Monitors `:nodeup` and `:nodedown` events and keeps Horde cluster membership
  in sync so distributed processes can migrate across nodes transparently.

  On startup, seeds Horde with all currently connected nodes. On each
  `:nodeup` / `:nodedown` event, it recomputes the current member list and
  calls `Horde.Cluster.set_members/2` for both the distributed supervisor and
  registry.

  ## Horde components managed

  - `Pincer.Core.Session.HordeSupervisor`
  - `Pincer.Core.Session.HordeRegistry`
  - `Pincer.Core.Project.HordeSupervisor`
  - `Pincer.Core.Project.HordeRegistry`
  """

  use GenServer
  require Logger

  @horde_supervisors [
    Pincer.Core.Session.HordeSupervisor,
    Pincer.Core.Project.HordeSupervisor
  ]

  @horde_registries [
    Pincer.Core.Session.HordeRegistry,
    Pincer.Core.Project.HordeRegistry
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    set_members()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("[Cluster] Node up: #{node} — syncing Horde members")
    set_members()
    {:noreply, state}
  end

  def handle_info({:nodedown, node, _info}, state) do
    Logger.info("[Cluster] Node down: #{node} — syncing Horde members")
    set_members()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp set_members do
    nodes = [Node.self() | Node.list()]

    for name <- @horde_supervisors do
      members = Enum.map(nodes, fn n -> {name, n} end)
      Horde.Cluster.set_members(name, members)
    end

    for name <- @horde_registries do
      members = Enum.map(nodes, fn n -> {name, n} end)
      Horde.Cluster.set_members(name, members)
    end
  end
end
