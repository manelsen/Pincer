defmodule Pincer.Core.AgentRegistryTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.AgentRegistry
  alias Pincer.Test.WorkspaceEnv

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "pincer_agent_registry_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    workspaces = WorkspaceEnv.put_absolute!(tmp)

    template_dir = Path.join(workspaces, ".template/.pincer")
    File.mkdir_p!(template_dir)
    File.write!(Path.join(template_dir, "BOOTSTRAP.md"), "# Template Bootstrap\n")
    File.write!(Path.join(template_dir, "IDENTITY.md"), "# Template Identity\n")
    File.write!(Path.join(template_dir, "SOUL.md"), "# Template Soul\n")
    File.write!(Path.join(template_dir, "USER.md"), "# Template User\n")
    File.write!(Path.join(tmp, "IDENTITY.md"), "# Legacy Identity\n")
    File.write!(Path.join(tmp, "SOUL.md"), "# Legacy Soul\n")

    on_exit(fn -> File.rm_rf!(tmp) end)

    :ok
  end

  test "create_root_agent!/0 generates opaque hexadecimal ids and isolated workspace scaffold" do
    %{agent_id: agent_id, workspace_path: workspace_path} =
      AgentRegistry.create_root_agent!()

    assert agent_id =~ ~r/^[0-9a-f]{6}$/
    assert workspace_path == AgentPaths.workspace_root(agent_id)
    assert File.read!(AgentPaths.bootstrap_path(workspace_path)) =~ "Template Bootstrap"
    # IDENTITY and SOUL are NOT seeded — deferred to bootstrap ritual
    refute File.exists?(AgentPaths.identity_path(workspace_path))
    refute File.exists?(AgentPaths.soul_path(workspace_path))
  end

  test "create_root_agent!/1 accepts explicit ids" do
    %{agent_id: "annie", workspace_path: workspace_path} =
      AgentRegistry.create_root_agent!(agent_id: "annie")

    assert workspace_path == AgentPaths.workspace_root("annie")
    # IDENTITY and SOUL are NOT seeded — deferred to bootstrap ritual
    refute File.exists?(AgentPaths.identity_path(workspace_path))
    refute File.exists?(AgentPaths.soul_path(workspace_path))
  end
end
