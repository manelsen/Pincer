defmodule Pincer.Core.ClusterTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Cluster
  alias Pincer.Core.Cluster.NodeObserver
  alias Pincer.Core.Registry, as: CoreRegistry
  alias Pincer.Core.Session.HordeSupervisor
  alias Pincer.Core.Project.HordeSupervisor, as: ProjectHordeSupervisor

  @session_horde_registry Pincer.Core.Session.HordeRegistry
  @project_horde_registry Pincer.Core.Project.HordeRegistry

  describe "Cluster.topologies/0" do
    test "returns empty list when no cluster config present" do
      original = Application.get_env(:pincer, :cluster_config)

      on_exit(fn ->
        if original,
          do: Application.put_env(:pincer, :cluster_config, original),
          else: Application.delete_env(:pincer, :cluster_config)
      end)

      topologies = Cluster.topologies()
      assert is_list(topologies)
    end

    test "returns a keyword list" do
      assert is_list(Cluster.topologies())
    end
  end

  describe "HordeRegistry — session registry" do
    test "is alive" do
      assert Process.whereis(@session_horde_registry) != nil
    end

    test "via_tuple returns a {:via, Horde.Registry, ...} tuple" do
      result = CoreRegistry.via_tuple(@session_horde_registry, "session-abc")
      assert {:via, Horde.Registry, {@session_horde_registry, "session-abc"}} = result
    end

    test "lookup returns [] for unknown session" do
      assert CoreRegistry.lookup(@session_horde_registry, "no-such-session") == []
    end
  end

  describe "HordeSupervisor — session supervisor" do
    test "is alive" do
      assert Process.whereis(HordeSupervisor) != nil
    end

    test "which_children returns a list" do
      assert is_list(Horde.DynamicSupervisor.which_children(HordeSupervisor))
    end
  end

  describe "Project.HordeRegistry" do
    test "is alive" do
      assert Process.whereis(@project_horde_registry) != nil
    end

    test "via_tuple returns a {:via, Horde.Registry, ...} tuple" do
      result = CoreRegistry.via_tuple(@project_horde_registry, "proj-xyz")
      assert {:via, Horde.Registry, {@project_horde_registry, "proj-xyz"}} = result
    end
  end

  describe "Project.HordeSupervisor" do
    test "is alive" do
      assert Process.whereis(ProjectHordeSupervisor) != nil
    end
  end

  describe "NodeObserver" do
    test "is alive" do
      assert Process.whereis(NodeObserver) != nil
    end

    test "handles unknown messages gracefully" do
      send(NodeObserver, :unknown_message)
      Process.sleep(20)
      assert Process.whereis(NodeObserver) != nil
    end
  end
end
