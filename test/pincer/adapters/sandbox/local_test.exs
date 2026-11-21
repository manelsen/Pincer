defmodule Pincer.Adapters.Sandbox.LocalTest do
  use ExUnit.Case, async: false

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
end
