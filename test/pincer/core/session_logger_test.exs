defmodule Pincer.Core.Session.LoggerTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Session.Logger

  test "writes session logs under workspace .pincer/sessions" do
    tmp = tempdir("session_logger")
    workspace = Path.join(tmp, "workspaces/logger_agent")

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)

    assert :ok =
             Logger.log("telegram/user:123", "user", "hello from workspace",
               workspace_path: workspace
             )

    log_path = AgentPaths.session_log_path(workspace, "telegram/user:123")
    assert File.exists?(log_path)

    log = File.read!(log_path)
    assert log =~ "hello from workspace"
    assert log =~ "USER"
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
