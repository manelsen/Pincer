defmodule Pincer.Core.Session.SupervisorTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Session.Server
  alias Pincer.Core.Session.Supervisor

  test "start_session/2 forwards template-only seed options for mapped agents" do
    session_id = "annie_supervisor_#{System.unique_integer([:positive])}"
    workspace = tempdir("session_supervisor_mapped")

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)

    on_exit(fn ->
      Supervisor.stop_session(session_id)
      File.rm_rf!(Path.dirname(Path.dirname(workspace)))
    end)

    assert {:ok, _pid} =
             Supervisor.start_session(
               session_id,
               workspace_path: workspace,
               allow_legacy_root_seed?: false,
               bootstrap?: false
             )

    Process.sleep(80)

    assert {:ok, _state} = Server.get_status(session_id)
    refute File.exists?(AgentPaths.identity_path(workspace))
    refute File.exists?(AgentPaths.soul_path(workspace))
    refute File.exists?(AgentPaths.user_path(workspace))
  end

  defp tempdir(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/annie")
    File.mkdir_p!(workspace)
    workspace
  end
end
