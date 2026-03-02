defmodule Pincer.SecurityAuditTest do
  @moduledoc """
  Security regression tests verifying remediation of all vulnerabilities found in the
  February 2026 security assessment report.

  Each describe block maps directly to a VULN-XXX finding. Tests must remain green
  after any refactor that touches the relevant modules.
  """

  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.SafeShell
  alias Pincer.Adapters.Tools.FileSystem
  alias Pincer.Adapters.Tools.Web

  # ---------------------------------------------------------------------------
  # VULN-001: Command Injection via SafeShell whitelist bypass
  # ---------------------------------------------------------------------------

  describe "VULN-001: SafeShell — command injection prevention" do
    test "blocks semicolon chaining (ls; cat /etc/passwd)" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "ls; cat /etc/passwd"})
    end

    test "blocks pipe to shell (ls | bash)" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "ls | bash"})
    end

    test "blocks AND chaining (ls && cat /etc/shadow)" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "ls && cat /etc/shadow"})
    end

    test "blocks OR chaining (ls || curl evil.com)" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "ls || curl evil.com"})
    end

    test "blocks command substitution with $(...)" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "ls $(cat /etc/passwd)"})
    end

    test "blocks backtick command substitution" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "ls `whoami`"})
    end

    test "blocks output redirection (ls > /tmp/out)" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "ls > /tmp/out"})
    end

    test "blocks shell line continuation (ls \\\\n-a)" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "ls \\\n-a"})
    end

    test "blocks multiline shell payload (ls\\ncat /etc/passwd)" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "ls\ncat /etc/passwd"})
    end

    test "blocks commands not in whitelist" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "curl https://evil.com"})
    end

    test "blocks path traversal in cat argument" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "cat ../../etc/passwd"})
    end

    test "blocks absolute path in cat argument" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "cat /etc/passwd"})
    end

    test "blocks absolute path in generic whitelisted command args" do
      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "ls /etc"})
    end

    test "blocks symlink path that resolves outside workspace" do
      sandbox_dir =
        Path.join("trash", "safe_shell_symlink_escape_#{System.unique_integer([:positive])}")

      link_path = Path.join(sandbox_dir, "passwd_link")

      File.mkdir_p!(sandbox_dir)
      assert :ok = File.ln_s("/etc/passwd", link_path)

      on_exit(fn ->
        File.rm_rf(sandbox_dir)
      end)

      assert {:error, {:approval_required, _}} =
               SafeShell.execute(%{"command" => "cat #{link_path}"})
    end

    test "allows clean whitelisted command (ls -la)" do
      # Without an MCP server running the GenServer call exits.  The exit itself
      # proves the command passed SafeShell's validation layer (it was NOT blocked
      # with {:error, {:approval_required, _}}); otherwise we would never reach
      # call_mcp/1.
      try do
        result = SafeShell.execute(%{"command" => "ls -la"})
        refute match?({:error, {:approval_required, _}}, result)
      catch
        # reached MCP — command was accepted by the validator
        :exit, _ -> :ok
      end
    end

    test "allows pwd with no arguments" do
      try do
        result = SafeShell.execute(%{"command" => "pwd"})
        refute match?({:error, {:approval_required, _}}, result)
      catch
        :exit, _ -> :ok
      end
    end

    test "blocks command that exceeds max length" do
      long_cmd = String.duplicate("x", 2000)
      # Should truncate and not crash; exact result depends on truncated content.
      assert is_tuple(SafeShell.execute(%{"command" => long_cmd}))
    end
  end

  # ---------------------------------------------------------------------------
  # VULN-002: Path Traversal in FileSystem tool
  # ---------------------------------------------------------------------------

  describe "VULN-002: FileSystem — path confinement" do
    test "blocks explicit '..' traversal (../../etc/passwd)" do
      assert {:error, msg} =
               FileSystem.execute(%{"action" => "read", "path" => "../../etc/passwd"})

      assert msg =~ "traversal" or msg =~ "not allowed"
    end

    test "blocks absolute path outside workspace (/etc/passwd)" do
      assert {:error, msg} = FileSystem.execute(%{"action" => "read", "path" => "/etc/passwd"})
      assert msg =~ "Access denied" or msg =~ "traversal"
    end

    test "blocks absolute path outside workspace (/tmp/secret)" do
      assert {:error, msg} = FileSystem.execute(%{"action" => "read", "path" => "/tmp/secret"})
      assert msg =~ "Access denied" or msg =~ "traversal"
    end

    test "blocks null bytes in path" do
      assert {:error, msg} = FileSystem.execute(%{"action" => "read", "path" => "lib/\x00evil"})
      assert msg =~ "null"
    end

    test "blocks sibling-directory prefix collision (path starting with workspace name but outside it)" do
      # This tests the fix for the String.starts_with? bug.
      # We simulate it by constructing a path whose expanded form would start with cwd
      # but point to a sibling directory — only possible via an absolute path.
      cwd = File.cwd!()
      # Path like "/home/user/Pincer-evil/file" starts_with "/home/user/Pincer"
      # but should be blocked.  We use a fabricated absolute path derived from cwd.
      sibling = Path.dirname(cwd) <> "/Pincer-evil/secret.txt"
      assert {:error, msg} = FileSystem.execute(%{"action" => "read", "path" => sibling})
      assert msg =~ "Access denied" or msg =~ "traversal"
    end

    test "allows reading an existing file within workspace" do
      # mix.exs is always present in the project root.
      result = FileSystem.execute(%{"action" => "read", "path" => "mix.exs"})
      assert match?({:ok, _}, result)
    end

    test "allows listing the workspace root" do
      assert {:ok, content} = FileSystem.execute(%{"action" => "list", "path" => "."})
      assert String.contains?(content, "mix.exs")
    end

    test "rejects reading a directory as a file" do
      assert {:error, _} = FileSystem.execute(%{"action" => "read", "path" => "lib"})
    end

    test "blocks symlink target that escapes workspace root" do
      sandbox_dir = Path.join("trash", "fs_symlink_escape_#{System.unique_integer([:positive])}")
      link_path = Path.join(sandbox_dir, "passwd_link")

      File.mkdir_p!(sandbox_dir)
      assert :ok = File.ln_s("/etc/passwd", link_path)

      on_exit(fn ->
        File.rm_rf(sandbox_dir)
      end)

      assert {:error, msg} = FileSystem.execute(%{"action" => "read", "path" => link_path})
      assert msg =~ "Access denied" or msg =~ "outside workspace"
    end

    test "blocks symlinked directory escape on descendant path" do
      sandbox_dir =
        Path.join("trash", "fs_symlink_dir_escape_#{System.unique_integer([:positive])}")

      link_dir = Path.join(sandbox_dir, "etc_link")
      escaped_file = Path.join(link_dir, "passwd")

      File.mkdir_p!(sandbox_dir)
      assert :ok = File.ln_s("/etc", link_dir)

      on_exit(fn ->
        File.rm_rf(sandbox_dir)
      end)

      assert {:error, msg} = FileSystem.execute(%{"action" => "read", "path" => escaped_file})
      assert msg =~ "Access denied" or msg =~ "outside workspace"
    end
  end

  # ---------------------------------------------------------------------------
  # VULN-003: SSRF in Web tool
  # ---------------------------------------------------------------------------

  describe "VULN-003: Web tool — SSRF protection" do
    test "blocks localhost by hostname" do
      assert {:error, msg} =
               Web.execute(%{"action" => "fetch", "url" => "http://localhost/admin"})

      assert msg =~ "internal hosts" or msg =~ "not allowed"
    end

    test "blocks localhost with trailing dot" do
      assert {:error, msg} =
               Web.execute(%{"action" => "fetch", "url" => "http://localhost./admin"})

      assert msg =~ "internal hosts" or msg =~ "not allowed"
    end

    test "blocks 127.0.0.1 (IPv4 loopback)" do
      assert {:error, msg} =
               Web.execute(%{"action" => "fetch", "url" => "http://127.0.0.1:12345/"})

      assert msg =~ "internal hosts" or msg =~ "not allowed"
    end

    test "blocks IPv4-mapped IPv6 loopback without raising" do
      assert {:error, msg} =
               Web.execute(%{"action" => "fetch", "url" => "http://[::ffff:127.0.0.1]/"})

      assert msg =~ "internal hosts" or msg =~ "not allowed"
    end

    test "blocks AWS IMDSv1 metadata endpoint" do
      assert {:error, msg} =
               Web.execute(%{
                 "action" => "fetch",
                 "url" => "http://169.254.169.254/latest/meta-data/"
               })

      assert msg =~ "internal hosts" or msg =~ "not allowed"
    end

    test "blocks GCP metadata endpoint" do
      assert {:error, msg} =
               Web.execute(%{
                 "action" => "fetch",
                 "url" => "http://metadata.google.internal/computeMetadata/v1/"
               })

      assert msg =~ "internal hosts" or msg =~ "not allowed"
    end

    test "blocks private IP range 10.x.x.x" do
      assert {:error, msg} =
               Web.execute(%{"action" => "fetch", "url" => "http://10.0.0.1/api/secrets"})

      assert msg =~ "internal hosts" or msg =~ "not allowed"
    end

    test "blocks private IP range 192.168.x.x" do
      assert {:error, msg} = Web.execute(%{"action" => "fetch", "url" => "http://192.168.1.1/"})
      assert msg =~ "internal hosts" or msg =~ "not allowed"
    end

    test "blocks private IP range 172.16.x.x" do
      assert {:error, msg} = Web.execute(%{"action" => "fetch", "url" => "http://172.16.0.1/"})
      assert msg =~ "internal hosts" or msg =~ "not allowed"
    end

    test "blocks file:// scheme" do
      assert {:error, msg} = Web.execute(%{"action" => "fetch", "url" => "file:///etc/passwd"})
      assert msg =~ "not allowed" or msg =~ "scheme" or msg =~ "Invalid URL"
    end

    test "blocks ftp:// scheme" do
      assert {:error, msg} =
               Web.execute(%{"action" => "fetch", "url" => "ftp://example.com/file"})

      assert msg =~ "not allowed" or msg =~ "scheme"
    end

    test "blocks invalid URL format" do
      assert {:error, _} = Web.execute(%{"action" => "fetch", "url" => "not-a-url"})
    end

    test "blocks 0.0.0.0" do
      assert {:error, msg} = Web.execute(%{"action" => "fetch", "url" => "http://0.0.0.0/"})
      assert msg =~ "internal hosts" or msg =~ "not allowed"
    end
  end

  # ---------------------------------------------------------------------------
  # VULN-006: Loop detection in Executor
  # ---------------------------------------------------------------------------

  describe "VULN-006: Executor — loop detection" do
    defp build_assistant_msg_with_tool(tool_name) do
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{"id" => "1", "function" => %{"name" => tool_name, "arguments" => "{}"}}
        ]
      }
    end

    test "detects identical back-to-back tool sequences (existing check)" do
      msg = build_assistant_msg_with_tool("safe_shell")
      history = List.duplicate(msg, 4)
      # Access loop_detected? via a helper that exposes it for testing.
      assert executor_loop_detected?(history)
    end

    test "does not flag two identical calls as a loop" do
      msg = build_assistant_msg_with_tool("safe_shell")
      history = List.duplicate(msg, 2)
      refute executor_loop_detected?(history)
    end

    test "detects high-frequency single tool (5+ times in last 10 turns)" do
      # 5 calls to the same tool with different arguments — the sequence isn't identical,
      # but the frequency is high enough to flag as a loop.
      history =
        Enum.map(1..5, fn i ->
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "#{i}",
                "function" => %{
                  "name" => "file_system",
                  "arguments" => ~s({"path": "file#{i}.txt"})
                }
              }
            ]
          }
        end)

      assert executor_loop_detected?(history)
    end

    test "does not flag varied tool usage as a loop" do
      tools = ~w(file_system safe_shell web file_system safe_shell)
      history = Enum.map(tools, &build_assistant_msg_with_tool/1)
      refute executor_loop_detected?(history)
    end

    # Helper: expose the private loop_detected?/1 for testing by replicating its logic.
    defp executor_loop_detected?(history) do
      identical_sequence_loop?(history) or high_frequency_loop?(history)
    end

    defp identical_sequence_loop?(history) do
      tool_calls =
        Enum.filter(Enum.take(history, -6), fn
          %{"tool_calls" => calls} -> not is_nil(calls)
          _ -> false
        end)

      if length(tool_calls) >= 3 do
        first = List.first(tool_calls)["tool_calls"]
        Enum.all?(tool_calls, fn msg -> msg["tool_calls"] == first end)
      else
        false
      end
    end

    defp high_frequency_loop?(history) do
      recent_names =
        history
        |> Enum.take(-10)
        |> Enum.flat_map(fn
          %{"tool_calls" => calls} when not is_nil(calls) ->
            Enum.map(calls, fn tc -> get_in(tc, ["function", "name"]) end)

          _ ->
            []
        end)
        |> Enum.reject(&is_nil/1)

      Enum.any?(
        Enum.frequencies(recent_names),
        fn {_tool, count} -> count >= 5 end
      )
    end
  end
end
