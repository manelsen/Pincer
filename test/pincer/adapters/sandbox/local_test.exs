defmodule Pincer.Adapters.Sandbox.LocalTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Sandbox.Bwrap
  alias Pincer.Adapters.Sandbox.Local

  defmodule FakeToolRegistry do
    @behaviour Pincer.Ports.ToolRegistry

    @impl true
    def list_tools, do: []

    @impl true
    def execute_tool("run_command", args, context) do
      if pid = Application.get_env(:pincer, :local_sandbox_test_pid) do
        send(pid, {:tool_registry_run, args, context})
      end

      {:ok, "registry-output: #{args["command"]}"}
    end

    def execute_tool(_name, _args, _context), do: {:error, "Tool not found"}
  end

  defp conformance_run_opts(workspace) do
    [
      transport: :tool_registry,
      workspace_path: workspace,
      cwd: workspace
    ]
  end

  setup do
    prev_tools = Application.get_env(:pincer, :tool_adapters, :__unset__)
    prev_sandbox = Application.get_env(:pincer, :sandbox, :__unset__)
    Application.put_env(:pincer, :tool_adapters, [FakeToolRegistry])
    Application.delete_env(:pincer, :sandbox)
    Application.put_env(:pincer, :local_sandbox_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:pincer, :local_sandbox_test_pid)

      for {key, prev} <- [tool_adapters: prev_tools, sandbox: prev_sandbox] do
        case prev do
          :__unset__ -> Application.delete_env(:pincer, key)
          val -> Application.put_env(:pincer, key, val)
        end
      end
    end)

    workspace =
      Path.join(System.tmp_dir!(), "pincer_local_sbx_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    {:ok, workspace: workspace}
  end

  use Pincer.Test.Support.SandboxConformance, adapter: Local, backend: :local

  describe "tool_registry transport (default)" do
    test "forwards command and confined cwd to MCP run_command", %{workspace: workspace} do
      assert {:ok, %{output: "registry-output: ls -la", exit_code: 0, backend: :local}} =
               Local.run("ls -la", workspace_path: workspace, cwd: workspace)

      expected_cwd = Path.expand(workspace)
      assert_received {:tool_registry_run, %{"command" => "ls -la", "cwd" => ^expected_cwd}, %{}}
    end

    test "omits cwd when restrict_to_workspace is false and no cwd provided" do
      assert {:ok, %{output: "registry-output: pwd", exit_code: 0, backend: :local}} =
               Local.run("pwd", restrict_to_workspace: false)

      assert_received {:tool_registry_run, payload, %{}}
      assert payload == %{"command" => "pwd"}
      refute Map.has_key?(payload, "cwd")
    end

    test "wraps tool registry errors" do
      defmodule FailingToolRegistry do
        @behaviour Pincer.Ports.ToolRegistry
        @impl true
        def list_tools, do: []
        @impl true
        def execute_tool("run_command", _args, _ctx), do: {:error, :mcp_down}
      end

      Application.put_env(:pincer, :tool_adapters, [FailingToolRegistry])

      assert {:error, "Shell execution failed: :mcp_down"} =
               Local.run("pwd", restrict_to_workspace: false)
    end
  end

  describe "os transport" do
    test "executes command via injectable runner with non-zero exit code preserved", %{
      workspace: workspace
    } do
      test_pid = self()

      runner = fn cmd, cmd_opts ->
        send(test_pid, {:os_runner, cmd, cmd_opts})
        {"failed output", 2}
      end

      assert {:ok,
              %{
                output: "failed output",
                exit_code: 2,
                backend: :local,
                metadata: %{transport: :os}
              }} =
               Local.run("git status",
                 transport: :os,
                 runner: runner,
                 workspace_path: workspace,
                 env: [{"MY_VAR", "123"}]
               )

      assert_received {:os_runner, "git status", cmd_opts}
      assert Keyword.get(cmd_opts, :cd) == Path.expand(workspace)
      assert Keyword.get(cmd_opts, :env) == [{"MY_VAR", "123"}]
    end

    test "executes real command cleanly with default runner", %{workspace: workspace} do
      assert {:ok, %{output: output, exit_code: 0, backend: :local}} =
               Local.run("pwd",
                 transport: :os,
                 workspace_path: workspace,
                 timeout_ms: 5_000
               )

      assert String.trim(output) == Path.expand(workspace)
    end

    test "enforces timeout_ms and returns {:error, :timeout}", %{workspace: workspace} do
      slow_runner = fn _cmd, _opts ->
        Process.sleep(300)
        {"late", 0}
      end

      assert {:error, :timeout} =
               Local.run("pwd",
                 transport: :os,
                 runner: slow_runner,
                 workspace_path: workspace,
                 timeout_ms: 30
               )
    end

    test "rejects commands outside the allowlist before invoking the runner", %{
      workspace: workspace
    } do
      runner = fn _cmd, _opts -> flunk("runner must not be invoked") end

      assert {:error, {:command_not_allowed, _reason}} =
               Local.run("curl http://evil.example",
                 transport: :os,
                 runner: runner,
                 workspace_path: workspace
               )
    end
  end

  describe "bwrap transport" do
    test "routes to bwrap and builds an isolated argv", %{workspace: workspace} do
      fake_bwrap = fake_executable!(workspace, "bwrap")
      fake_prlimit = fake_executable!(workspace, "prlimit")
      test_pid = self()

      runner = fn exe, args, cmd_opts ->
        send(test_pid, {:bwrap_runner, exe, args, cmd_opts})
        {"bwrap-output\n", 0}
      end

      assert {:ok,
              %{
                output: "bwrap-output\n",
                exit_code: 0,
                backend: :local,
                metadata: %{transport: :bwrap, network: :none}
              }} =
               Local.run("pwd",
                 transport: "bwrap",
                 workspace_path: workspace,
                 cwd: workspace,
                 bwrap_available: true,
                 bwrap_runner: runner,
                 bwrap: %{
                   "executable" => fake_bwrap,
                   "prlimit_executable" => fake_prlimit,
                   "limits" => :disabled,
                   "network" => "none"
                 }
               )

      assert_received {:bwrap_runner, ^fake_bwrap, args, cmd_opts}
      assert pair_at?(args, "--bind", Path.expand(workspace))
      assert pair_at?(args, "--chdir", "/workspace")
      assert Enum.take(args, -4) == ["--", "/bin/sh", "-c", "pwd"]
      assert Keyword.get(cmd_opts, :stderr_to_stdout) == true
    end

    test "forwards validated env into bwrap", %{workspace: workspace} do
      fake_bwrap = fake_executable!(workspace, "bwrap")
      fake_prlimit = fake_executable!(workspace, "prlimit")
      test_pid = self()

      runner = fn _exe, args, _cmd_opts ->
        send(test_pid, {:bwrap_args, args})
        {"", 0}
      end

      assert {:ok, _result} =
               Local.run("pwd",
                 transport: :bwrap,
                 workspace_path: workspace,
                 bwrap_available: true,
                 bwrap_runner: runner,
                 env: [{"FOO", "bar"}],
                 bwrap: %{
                   executable: fake_bwrap,
                   prlimit_executable: fake_prlimit,
                   limits: :disabled
                 }
               )

      assert_received {:bwrap_args, args}
      assert setenv?(args, "FOO", "bar")
    end

    test "fails closed when bwrap is unavailable and never calls the runner", %{
      workspace: workspace
    } do
      test_pid = self()

      runner = fn _exe, _args, _cmd_opts ->
        send(test_pid, :bwrap_runner_called)
        {"", 0}
      end

      assert {:error, {:bwrap_unavailable, _reason}} =
               Local.run("pwd",
                 transport: "bwrap",
                 workspace_path: workspace,
                 bwrap_available: false,
                 bwrap_runner: runner
               )

      refute_received :bwrap_runner_called
    end

    test "fails closed via a bwrap_probe function", %{workspace: workspace} do
      test_pid = self()

      runner = fn _exe, _args, _cmd_opts ->
        send(test_pid, :bwrap_runner_called)
        {"", 0}
      end

      assert {:error, {:bwrap_unavailable, _reason}} =
               Local.run("pwd",
                 transport: "bwrap",
                 workspace_path: workspace,
                 bwrap_probe: fn -> {:error, :no_user_namespaces} end,
                 bwrap_runner: runner
               )

      refute_received :bwrap_runner_called
    end

    test "keeps WorkspaceGuard in the path and rejects blocked commands", %{
      workspace: workspace
    } do
      runner = fn _exe, _args, _cmd_opts -> flunk("bwrap runner must not be invoked") end

      assert {:error, {:command_not_allowed, _reason}} =
               Local.run("curl http://evil.example",
                 transport: "bwrap",
                 workspace_path: workspace,
                 bwrap_available: true,
                 bwrap_runner: runner
               )
    end

    test "bwrap: true opts in when transport is absent", %{workspace: workspace} do
      fake_bwrap = fake_executable!(workspace, "bwrap")
      fake_prlimit = fake_executable!(workspace, "prlimit")

      Application.put_env(:pincer, :sandbox, %{
        "local" => %{
          "bwrap" => %{
            "executable" => fake_bwrap,
            "prlimit_executable" => fake_prlimit,
            "limits" => :disabled
          }
        }
      })

      runner = fn _exe, _args, _cmd_opts -> {"opted-in\n", 0} end

      assert {:ok, %{metadata: %{transport: :bwrap}}} =
               Local.run("pwd",
                 workspace_path: workspace,
                 bwrap_available: true,
                 bwrap_runner: runner
               )
    end

    test "an explicit transport wins over bwrap: true", %{workspace: workspace} do
      Application.put_env(:pincer, :sandbox, %{
        "local" => %{"transport" => "os", "bwrap" => true}
      })

      test_pid = self()

      os_runner = fn cmd, _cmd_opts ->
        send(test_pid, {:os_runner, cmd})
        {"", 0}
      end

      assert {:ok, %{metadata: %{transport: :os}}} =
               Local.run("pwd",
                 workspace_path: workspace,
                 runner: os_runner,
                 bwrap_available: false
               )

      assert_received {:os_runner, "pwd"}
    end

    test "available?/0 and probe/0 use bwrap when configured", %{workspace: workspace} do
      bwrap_script = fake_executable!(workspace, "bwrap-probe")

      with_bwrap_binary(bwrap_script, fn ->
        Application.put_env(:pincer, :sandbox, %{
          "local" => %{
            "transport" => "bwrap",
            "bwrap" => %{"limits" => "disabled"}
          }
        })

        assert Local.available?()
        assert Local.probe() == :ok
      end)
    end

    test "probe/0 fails when active limits lack prlimit", %{workspace: workspace} do
      bwrap_script = fake_executable!(workspace, "bwrap-probe-ok")
      missing = Path.join(workspace, "missing-prlimit")

      with_bwrap_binary(bwrap_script, fn ->
        Application.put_env(:pincer, :sandbox, %{
          "local" => %{
            "transport" => "bwrap",
            "bwrap" => %{"prlimit_executable" => missing}
          }
        })

        refute Local.available?()
        assert Local.probe() == {:error, {:prlimit_unavailable, missing}}
      end)
    end

    test "a failing bwrap probe never falls back to os", %{workspace: workspace} do
      bwrap_script = fake_executable!(workspace, "bwrap-fail", "#!/bin/sh\nexit 1\n")

      with_bwrap_binary(bwrap_script, fn ->
        Application.put_env(:pincer, :sandbox, %{
          "local" => %{"transport" => "bwrap"}
        })

        refute Local.available?()
        assert {:error, _reason} = Local.probe()
      end)
    end

    test "probe/0 returns :ok for the os transport" do
      Application.put_env(:pincer, :sandbox, %{"local" => %{"transport" => "os"}})

      assert Local.available?()
      assert Local.probe() == :ok
    end
  end

  # --- Helpers ---

  defp fake_executable!(dir, name, body \\ "#!/bin/sh\nexit 0\n") do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end

  defp with_bwrap_binary(path, fun) do
    previous = System.get_env("PINCER_BWRAP_BINARY")
    System.put_env("PINCER_BWRAP_BINARY", path)
    Bwrap.reset_probe()

    on_exit(fn ->
      Bwrap.reset_probe()

      case previous do
        nil -> System.delete_env("PINCER_BWRAP_BINARY")
        value -> System.put_env("PINCER_BWRAP_BINARY", value)
      end
    end)

    fun.()
  end

  defp pair_at?(args, flag, value) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [left, right] -> left == flag and right == value end)
  end

  defp setenv?(args, key, value) do
    args
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.any?(fn [flag, k, v] -> flag == "--setenv" and k == key and v == value end)
  end
end
