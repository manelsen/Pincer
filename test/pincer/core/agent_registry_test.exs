defmodule Pincer.Core.AgentRegistryTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.AgentRegistry

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "pincer_agent_registry_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    cwd = File.cwd!()
    File.cd!(tmp)

    File.mkdir_p!("workspaces/.template/.pincer")
    File.write!("workspaces/.template/.pincer/BOOTSTRAP.md", "# Template Bootstrap\n")
    File.write!("IDENTITY.md", "# Legacy Identity\n")
    File.write!("SOUL.md", "# Legacy Soul\n")

    on_exit(fn ->
      File.cd!(cwd)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "create_root_agent!/0 generates opaque hexadecimal ids and isolated workspace scaffold" do
    %{agent_id: agent_id, workspace_path: workspace_path} =
      AgentRegistry.create_root_agent!()

    assert agent_id =~ ~r/^[0-9a-f]{6}$/
    assert workspace_path == AgentPaths.workspace_root(agent_id)
    assert File.read!(AgentPaths.bootstrap_path(workspace_path)) == "# Template Bootstrap\n"
    refute File.exists?(AgentPaths.identity_path(workspace_path))
    refute File.exists?(AgentPaths.soul_path(workspace_path))
  end

  test "create_root_agent!/1 accepts explicit ids and does not copy legacy persona" do
    %{agent_id: "annie", workspace_path: workspace_path} =
      AgentRegistry.create_root_agent!(agent_id: "annie")

    assert workspace_path == AgentPaths.workspace_root("annie")
    refute File.exists?(AgentPaths.identity_path(workspace_path))
    refute File.exists?(AgentPaths.soul_path(workspace_path))
  end
end
