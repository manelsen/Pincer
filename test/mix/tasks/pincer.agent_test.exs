defmodule Mix.Tasks.Pincer.AgentTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Pairing

  @task "pincer.agent"

  setup do
    tmp = Path.join(System.tmp_dir!(), "pincer_agent_task_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    cwd = File.cwd!()
    File.cd!(tmp)

    File.mkdir_p!("workspaces/.template/.pincer")
    File.write!("workspaces/.template/.pincer/BOOTSTRAP.md", "# Template Bootstrap\n")
    File.write!("workspaces/.template/.pincer/MEMORY.md", "# Template Memory\n")
    File.write!("workspaces/.template/.pincer/HISTORY.md", "# Template History\n")

    File.write!("IDENTITY.md", "# Legacy Identity\n")
    File.write!("SOUL.md", "# Legacy Soul\n")
    File.write!("USER.md", "# Legacy User\n")
    File.write!("BOOTSTRAP.md", "# Legacy Bootstrap\n")

    previous_pairing = Application.get_env(:pincer, :pairing, %{})

    Application.put_env(:pincer, :pairing, %{
      persist: true,
      store_path: "sessions/pairing_store.dets"
    })

    Pairing.reset()

    on_exit(fn ->
      Pairing.reset()
      Application.put_env(:pincer, :pairing, previous_pairing)
      File.cd!(cwd)
      File.rm_rf!(tmp)
      Mix.Task.reenable(@task)
    end)

    :ok
  end

  test "new creates isolated workspace scaffold without copying legacy persona" do
    output =
      capture_io(fn ->
        Mix.Task.run(@task, ["new", "annie"])
      end)

    workspace = AgentPaths.workspace_root("annie")

    assert File.read!(AgentPaths.bootstrap_path(workspace)) == "# Template Bootstrap\n"
    assert File.read!(AgentPaths.memory_path(workspace)) == "# Template Memory\n"
    assert File.read!(AgentPaths.history_path(workspace)) == "# Template History\n"
    assert File.dir?(AgentPaths.sessions_dir(workspace))

    refute File.exists?(AgentPaths.identity_path(workspace))
    refute File.exists?(AgentPaths.soul_path(workspace))
    refute File.exists?(AgentPaths.user_path(workspace))

    assert output =~ "workspaces/annie/.pincer"
  end

  test "new without args creates an opaque agent id" do
    output =
      capture_io(fn ->
        Mix.Task.run(@task, ["new"])
      end)

    [_, agent_id] = Regex.run(~r/Agent ID:\s+([0-9a-f]{6})/, output)
    workspace = AgentPaths.workspace_root(agent_id)

    assert File.dir?(AgentPaths.pincer_dir(workspace))
  end

  test "new is idempotent and preserves existing persona files" do
    capture_io(fn ->
      Mix.Task.run(@task, ["new", "annie"])
    end)

    workspace = AgentPaths.workspace_root("annie")

    File.write!(AgentPaths.bootstrap_path(workspace), "# Annie Bootstrap\n")
    File.write!(AgentPaths.identity_path(workspace), "# Annie Identity\n")
    File.write!(AgentPaths.soul_path(workspace), "# Annie Soul\n")
    File.write!(AgentPaths.user_path(workspace), "# Annie User\n")

    Mix.Task.reenable(@task)

    capture_io(fn ->
      Mix.Task.run(@task, ["new", "annie"])
    end)

    assert File.read!(AgentPaths.bootstrap_path(workspace)) == "# Annie Bootstrap\n"
    assert File.read!(AgentPaths.identity_path(workspace)) == "# Annie Identity\n"
    assert File.read!(AgentPaths.soul_path(workspace)) == "# Annie Soul\n"
    assert File.read!(AgentPaths.user_path(workspace)) == "# Annie User\n"
  end

  test "invalid usage raises a helpful error" do
    assert_raise Mix.Error,
                 ~r/mix pincer\.agent new \[agent_id\].*mix pincer\.agent pair \[agent_id\]/s,
                 fn ->
                   capture_io(fn ->
                     Mix.Task.run(@task, [])
                   end)
                 end

    Mix.Task.reenable(@task)

    assert_raise Mix.Error,
                 ~r/mix pincer\.agent new \[agent_id\].*mix pincer\.agent pair \[agent_id\]/s,
                 fn ->
                   capture_io(fn ->
                     Mix.Task.run(@task, ["pair", "annie", "oops"])
                   end)
                 end

    Mix.Task.reenable(@task)

    assert_raise Mix.Error, ~r/agent_id must match/, fn ->
      capture_io(fn ->
        Mix.Task.run(@task, ["new", "../oops"])
      end)
    end
  end

  test "pair annie emits a targeted telegram pairing code for an existing root agent" do
    capture_io(fn ->
      Mix.Task.run(@task, ["new", "annie"])
    end)

    Mix.Task.reenable(@task)

    output =
      capture_io(fn ->
        Mix.Task.run(@task, ["pair", "annie"])
      end)

    assert output =~ "Target agent: annie"
    [_, code] = Regex.run(~r/Pairing code:\s+([A-Za-z0-9_-]+)/, output)

    assert :ok = Pairing.approve_code(:telegram, "123", code)

    assert Pairing.bound_agent_id(:telegram, "123") == "annie"
  end

  test "pair without agent emits a generic pairing code that binds to a new opaque agent" do
    output =
      capture_io(fn ->
        Mix.Task.run(@task, ["pair"])
      end)

    assert output =~ "Target agent: <new dedicated Telegram agent>"
    [_, code] = Regex.run(~r/Pairing code:\s+([A-Za-z0-9_-]+)/, output)

    assert :ok = Pairing.approve_code(:telegram, "456", code)

    agent_id = Pairing.bound_agent_id(:telegram, "456")

    assert agent_id =~ ~r/^[0-9a-f]{6}$/
    assert File.dir?(AgentPaths.pincer_dir(AgentPaths.workspace_root(agent_id)))
  end

  test "pair fails clearly when the target agent workspace does not exist" do
    assert_raise Mix.Error, ~r/Agent workspace not found/, fn ->
      capture_io(fn ->
        Mix.Task.run(@task, ["pair", "annie"])
      end)
    end
  end
end
