defmodule Pincer.Core.AgentPathsTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.AgentPaths

  test "ensure_workspace!/2 seeds root agent state inside workspace .pincer" do
    tmp = tempdir("agent_paths_root")
    workspace = Path.join(tmp, "workspaces/root_agent")

    File.write!(Path.join(tmp, "IDENTITY.md"), "# Root Identity\n")
    File.write!(Path.join(tmp, "SOUL.md"), "# Root Soul\n")
    File.write!(Path.join(tmp, "USER.md"), "# Root User\n")
    File.write!(Path.join(tmp, "BOOTSTRAP.md"), "# Root Bootstrap\n")

    assert workspace ==
             AgentPaths.ensure_workspace!(workspace, bootstrap?: true, legacy_root: tmp)

    assert File.read!(AgentPaths.identity_path(workspace)) == "# Root Identity\n"
    assert File.read!(AgentPaths.soul_path(workspace)) == "# Root Soul\n"
    assert File.read!(AgentPaths.user_path(workspace)) == "# Root User\n"
    assert File.read!(AgentPaths.bootstrap_path(workspace)) == "# Root Bootstrap\n"
    assert File.exists?(AgentPaths.memory_path(workspace))
    assert File.exists?(AgentPaths.history_path(workspace))
    assert File.dir?(AgentPaths.sessions_dir(workspace))
  end

  test "ensure_workspace!/2 seeds sub-agent from parent without bootstrap" do
    tmp = tempdir("agent_paths_subagent")
    parent_workspace = Path.join(tmp, "workspaces/parent")
    subagent_workspace = Path.join(tmp, "workspaces/child")

    AgentPaths.ensure_workspace!(parent_workspace, bootstrap?: false)
    File.write!(AgentPaths.identity_path(parent_workspace), "# Parent Identity\n")
    File.write!(AgentPaths.soul_path(parent_workspace), "# Parent Soul\n")
    File.write!(AgentPaths.user_path(parent_workspace), "# Parent User\n")
    File.write!(AgentPaths.bootstrap_path(parent_workspace), "# Should Not Leak\n")

    assert subagent_workspace ==
             AgentPaths.ensure_workspace!(
               subagent_workspace,
               bootstrap?: false,
               inherit_from: parent_workspace
             )

    assert File.read!(AgentPaths.identity_path(subagent_workspace)) == "# Parent Identity\n"
    assert File.read!(AgentPaths.soul_path(subagent_workspace)) == "# Parent Soul\n"
    assert File.read!(AgentPaths.user_path(subagent_workspace)) == "# Parent User\n"
    refute File.exists?(AgentPaths.bootstrap_path(subagent_workspace))
    refute AgentPaths.bootstrap_active?(subagent_workspace)
    assert File.exists?(AgentPaths.memory_path(subagent_workspace))
    assert File.exists?(AgentPaths.history_path(subagent_workspace))
  end

  test "ensure_workspace!/2 can disable legacy root persona seeding for mapped agents" do
    tmp = tempdir("agent_paths_mapped")
    workspace = Path.join(tmp, "workspaces/annie")

    File.write!(Path.join(tmp, "IDENTITY.md"), "# Legacy Identity\n")
    File.write!(Path.join(tmp, "SOUL.md"), "# Legacy Soul\n")
    File.write!(Path.join(tmp, "USER.md"), "# Legacy User\n")
    File.write!(Path.join(tmp, "BOOTSTRAP.md"), "# Legacy Bootstrap\n")

    assert workspace ==
             AgentPaths.ensure_workspace!(workspace, bootstrap?: true, legacy_root: false)

    refute File.exists?(AgentPaths.identity_path(workspace))
    refute File.exists?(AgentPaths.soul_path(workspace))
    refute File.exists?(AgentPaths.user_path(workspace))
    assert File.exists?(AgentPaths.bootstrap_path(workspace))
    assert File.exists?(AgentPaths.memory_path(workspace))
    assert File.exists?(AgentPaths.history_path(workspace))
  end

  defp tempdir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    ExUnit.Callbacks.on_exit(fn ->
      File.rm_rf!(path)
    end)

    path
  end
end
