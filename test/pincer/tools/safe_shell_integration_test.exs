defmodule Pincer.Adapters.Tools.SafeShellIntegrationTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.SafeShell

  defmodule FakeRunCommandRegistry do
    @behaviour Pincer.Ports.ToolRegistry

    @impl true
    def list_tools, do: []

    @impl true
    def execute_tool("run_command", args, context) do
      send(self(), {:run_command, args, context})
      {:ok, "ok"}
    end

    def execute_tool(_name, _args, _context), do: {:error, "Tool not found"}
  end

  setup do
    previous_tool_adapters = Application.get_env(:pincer, :tool_adapters)
    Application.put_env(:pincer, :tool_adapters, [FakeRunCommandRegistry])

    on_exit(fn ->
      if is_nil(previous_tool_adapters) do
        Application.delete_env(:pincer, :tool_adapters)
      else
        Application.put_env(:pincer, :tool_adapters, previous_tool_adapters)
      end
    end)

    root =
      Path.join(
        System.tmp_dir!(),
        "pincer_safe_shell_integration_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
    end)

    {:ok, %{root: root, context: %{"workspace_path" => root}}}
  end

  test "execute/2 forwards sanitized command with cwd when workspace is restricted", %{
    root: root,
    context: context
  } do
    File.write!(Path.join(root, "README.md"), "hello\n")

    assert {:ok, "ok"} =
             SafeShell.execute(
               %{"command" => "cat README.md"},
               context
             )

    assert_received {:run_command, %{"command" => "cat README.md", "cwd" => cwd}, %{}}
    assert cwd == Path.expand(root)
  end

  defmodule FakeSandbox do
    @behaviour Pincer.Ports.Sandbox

    @impl true
    def backend_name, do: :fake

    @impl true
    def available?, do: true

    @impl true
    def run(command, opts) do
      send(self(), {:sandbox_run, command, opts})

      case Process.get(:fake_sandbox_exit_code, 0) do
        0 ->
          {:ok,
           %{
             output: "from-sandbox: #{command}",
             exit_code: 0,
             backend: :fake,
             metadata: %{}
           }}

        code ->
          {:ok,
           %{
             output: "boom",
             exit_code: code,
             backend: :fake,
             metadata: %{}
           }}
      end
    end

    @impl true
    def cleanup(_scope_id), do: :ok
  end

  test "execute/2 omits cwd when workspace restriction is disabled", %{context: context} do
    assert {:ok, "ok"} =
             SafeShell.execute(
               %{"command" => "pwd", "restrict_to_workspace" => false},
               context
             )

    assert_received {:run_command, %{"command" => "pwd"}, %{}}
  end

  test "execute/2 dispatches through Pincer.Ports.Sandbox adapter and maps non-zero exit code",
       %{root: root, context: context} do
    previous_sandbox = Application.get_env(:pincer, :sandbox_adapter)
    Application.put_env(:pincer, :sandbox_adapter, FakeSandbox)

    on_exit(fn ->
      Process.delete(:fake_sandbox_exit_code)

      if previous_sandbox do
        Application.put_env(:pincer, :sandbox_adapter, previous_sandbox)
      else
        Application.delete_env(:pincer, :sandbox_adapter)
      end
    end)

    assert {:ok, "from-sandbox: ls"} = SafeShell.execute(%{"command" => "ls"}, context)

    assert_received {:sandbox_run, "ls", opts}
    assert Keyword.get(opts, :cwd) == Path.expand(root)
    assert Keyword.get(opts, :workspace_path) == Path.expand(root)
    assert Keyword.get(opts, :restrict_to_workspace) == true

    Process.put(:fake_sandbox_exit_code, 2)

    assert {:error, "Command failed (exit 2): boom"} =
             SafeShell.execute(%{"command" => "ls"}, context)
  end
end
