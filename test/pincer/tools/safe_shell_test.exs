defmodule Pincer.Adapters.Tools.SafeShellTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.SafeShell
  alias Pincer.Core.WorkspaceGuard

  defmodule StubSandbox do
    @behaviour Pincer.Ports.Sandbox

    @impl true
    def backend_name, do: :stub

    @impl true
    def available?, do: true

    @impl true
    def run(command, opts) do
      send(self(), {:stub_sandbox_ran, command, opts})
      {:ok, %{output: "stub: #{command}", exit_code: 0, backend: :stub, metadata: %{}}}
    end

    @impl true
    def cleanup(_scope_id), do: :ok
  end

  setup do
    previous_sandbox = Application.get_env(:pincer, :sandbox_adapter, :__unset__)
    Application.put_env(:pincer, :sandbox_adapter, StubSandbox)

    tmp_root =
      Path.join(System.tmp_dir!(), "pincer_safe_shell_unit_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_root)
    canary = Path.join(tmp_root, "keep_me.txt")
    File.write!(canary, "canary\n")

    on_exit(fn ->
      case previous_sandbox do
        :__unset__ -> Application.delete_env(:pincer, :sandbox_adapter)
        val -> Application.put_env(:pincer, :sandbox_adapter, val)
      end

      File.rm_rf(tmp_root)
    end)

    {:ok, workspace: tmp_root, canary: canary}
  end

  describe "find hardening" do
    @dangerous_find_commands [
      "find . -delete",
      "find . -exec rm -rf {} +",
      "find . -execdir sh -c id +",
      "find . -ok rm {} +",
      "find . -okdir cat {} +",
      "find . -fprint out.txt",
      "find . -fprint0 out.txt",
      "find . -fprintf out.txt %p",
      "find . -fls out.txt",
      "find . -DELETE",
      "find . -exec=sh"
    ]

    for cmd <- @dangerous_find_commands do
      test "requires approval for dangerous find command: #{cmd}", %{
        workspace: workspace,
        canary: canary
      } do
        cmd = unquote(cmd)

        assert {:error, {:approval_required, ^cmd}} =
                 SafeShell.execute(
                   %{"command" => cmd, "restrict_to_workspace" => true},
                   %{"workspace_path" => workspace}
                 )

        refute_received {:stub_sandbox_ran, _, _}
        assert File.exists?(canary)

        assert {:error, _reason} =
                 SafeShell.approved_command_allowed?(cmd,
                   workspace_restrict: true,
                   workspace_root: workspace
                 )
      end
    end

    test "allows read-only find flags inside isolated workspace", %{workspace: workspace} do
      assert :ok =
               SafeShell.approved_command_allowed?("find . -maxdepth 2 -name *.txt",
                 workspace_restrict: true,
                 workspace_root: workspace
               )

      assert {:ok, "stub: find . -maxdepth 2 -name *.txt"} =
               SafeShell.execute(
                 %{
                   "command" => "find . -maxdepth 2 -name *.txt",
                   "restrict_to_workspace" => true
                 },
                 %{"workspace_path" => workspace}
               )

      assert_received {:stub_sandbox_ran, "find . -maxdepth 2 -name *.txt", _opts}
    end
  end

  describe "git log hardening" do
    for cmd <- [
          "git log --output=leak.txt",
          "git log --output leak.txt",
          "git log --ext-diff",
          "git log --textconv"
        ] do
      test "requires approval for dangerous git log command: #{cmd}", %{workspace: workspace} do
        cmd = unquote(cmd)

        assert {:error, {:approval_required, ^cmd}} =
                 SafeShell.execute(
                   %{"command" => cmd, "restrict_to_workspace" => true},
                   %{"workspace_path" => workspace}
                 )

        refute_received {:stub_sandbox_ran, _, _}

        assert {:error, _reason} =
                 SafeShell.approved_command_allowed?(cmd,
                   workspace_restrict: true,
                   workspace_root: workspace
                 )
      end
    end

    test "allows standard git log inspection", %{workspace: workspace} do
      assert :ok =
               SafeShell.approved_command_allowed?("git log -n 5 --oneline",
                 workspace_restrict: true,
                 workspace_root: workspace
               )

      assert {:ok, "stub: git log -n 5 --oneline"} =
               SafeShell.execute(
                 %{"command" => "git log -n 5 --oneline", "restrict_to_workspace" => true},
                 %{"workspace_path" => workspace}
               )

      assert_received {:stub_sandbox_ran, "git log -n 5 --oneline", _opts}
    end
  end

  describe "approval does not bypass validation" do
    test "rejects an approved command that fails the static checks", %{workspace: workspace} do
      cmd = "rm -rf /"

      assert {:error, {:approval_required, ^cmd}} =
               SafeShell.execute(
                 %{"command" => cmd, "restrict_to_workspace" => true},
                 %{"workspace_path" => workspace, "approval_granted" => true}
               )

      refute_received {:stub_sandbox_ran, _, _}
    end

    test "rejects an approved command with shell metacharacters", %{workspace: workspace} do
      cmd = "ls .; rm -rf keep_me.txt"

      assert {:error, {:approval_required, ^cmd}} =
               SafeShell.execute(
                 %{"command" => cmd, "restrict_to_workspace" => true},
                 %{"workspace_path" => workspace, "approval_granted" => true}
               )

      refute_received {:stub_sandbox_ran, _, _}
    end

    test "still runs an approved command that passes validation", %{workspace: workspace} do
      assert {:ok, "stub: ls ."} =
               SafeShell.execute(
                 %{"command" => "ls .", "restrict_to_workspace" => true},
                 %{"workspace_path" => workspace, "approval_granted" => true}
               )

      assert_received {:stub_sandbox_ran, "ls .", _opts}
    end
  end

  describe "WorkspaceGuard policy consolidation parity" do
    test "WorkspaceGuard.command_allowed?/2 and SafeShell.approved_command_allowed?/2 produce identical verdicts",
         %{workspace: workspace} do
      File.mkdir_p!(Path.join(workspace, "sub/dir"))
      File.write!(Path.join(workspace, "sub/dir/file.txt"), "ok\n")
      File.write!(Path.join(workspace, "mix.exs"), "defmodule Fixture.MixProject do\nend\n")
      File.write!(Path.join(workspace, "package.json"), ~s({"scripts":{"lint":"eslint ."}}))

      commands = [
        {"du -sh", :ok},
        {"du -sh sub/dir", :ok},
        {"du -sh ../outside", :error},
        {"find . -maxdepth 2", :ok},
        {"find . -delete", :error},
        {"find . -exec sh -c id \\;", :error},
        {"git log -n 5", :ok},
        {"git log --output=/tmp/x", :error},
        {"grep foo bar", :error},
        {"cat ../outside", :error},
        {"ls ../outside", :error},
        {"cat ~/.ssh/config", :error},
        {"ls; rm -rf /", :error},
        {"ls | cat", :error},
        {"ls $(id)", :error},
        {"ls `id`", :error},
        {"ls > out.txt", :error},
        {"ls\ncat /etc/passwd", :error},
        {"mix format", :ok},
        {"mix format /etc/passwd", :error},
        {"npm run lint", :ok},
        {"npm run release", :error}
      ]

      opts = [workspace_root: workspace, workspace_restrict: true]

      for {cmd, expected} <- commands do
        wg_verdict = WorkspaceGuard.command_allowed?(cmd, opts)
        ss_verdict = SafeShell.approved_command_allowed?(cmd, opts)

        assert wg_verdict == ss_verdict,
               "Verdict mismatch for #{inspect(cmd)}: WorkspaceGuard=#{inspect(wg_verdict)} SafeShell=#{inspect(ss_verdict)}"

        case expected do
          :ok -> assert wg_verdict == :ok
          :error -> assert match?({:error, _}, wg_verdict)
        end
      end
    end

    test "SafeShell delegates policy constants and parser to WorkspaceGuard" do
      source =
        Path.expand("../../../lib/pincer/adapters/tools/safe_shell.ex", __DIR__)
        |> File.read!()

      refute source =~ "@max_command_length"
      refute source =~ "@dangerous_chars"
      refute source =~ "@multiline_or_line_continuation"
      refute source =~ "@forbidden_find_flags"
      refute source =~ "@forbidden_git_log_flags"
      refute source =~ "defp parse_and_validate"
    end
  end
end
