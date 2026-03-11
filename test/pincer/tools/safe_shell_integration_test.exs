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
      Application.put_env(:pincer, :tool_adapters, previous_tool_adapters)
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

  test "execute/2 omits cwd when workspace restriction is disabled", %{context: context} do
    assert {:ok, "ok"} =
             SafeShell.execute(
               %{"command" => "pwd", "restrict_to_workspace" => false},
               context
             )

    assert_received {:run_command, %{"command" => "pwd"}, %{}}
  end
end
