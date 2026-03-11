defmodule Pincer.Core.WorkspaceGuardTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.WorkspaceGuard

  test "confine_path/2 blocks traversal with parent segments" do
    root = File.cwd!()

    assert {:error, "Path traversal (..) not allowed"} =
             WorkspaceGuard.confine_path("../../etc/passwd", root: root)
  end

  test "confine_path/2 blocks symlink escape outside workspace" do
    root = File.cwd!()
    sandbox = Path.join(root, "trash/ws_guard_symlink_#{System.unique_integer([:positive])}")
    link_path = Path.join(sandbox, "passwd_link")

    File.mkdir_p!(sandbox)
    assert :ok = File.ln_s("/etc/passwd", link_path)

    on_exit(fn ->
      File.rm_rf(sandbox)
    end)

    assert {:error, "Access denied: Path outside workspace"} =
             WorkspaceGuard.confine_path(link_path, root: root)
  end

  test "confine_path/2 blocks sibling path prefix collision outside workspace" do
    root = File.cwd!()
    sibling = Path.dirname(root) <> "/" <> Path.basename(root) <> "-evil/secret.txt"

    assert {:error, "Access denied: Path outside workspace"} =
             WorkspaceGuard.confine_path(sibling, root: root)
  end

  test "confine_path/2 accepts a path inside workspace" do
    root = File.cwd!()
    assert {:ok, safe} = WorkspaceGuard.confine_path("mix.exs", root: root)
    assert String.ends_with?(safe, "/mix.exs")
  end

  test "confine_path/2 rejects empty paths" do
    assert {:error, "Invalid path"} = WorkspaceGuard.confine_path("", root: File.cwd!())
  end

  test "confine_path/2 rejects null bytes" do
    assert {:error, "Path contains null bytes"} =
             WorkspaceGuard.confine_path("lib/\x00evil", root: File.cwd!())
  end

  test "confine_path/2 can allow parent segments when explicitly disabled and still confined" do
    root = Path.join(File.cwd!(), "trash/ws_guard_relaxed_#{System.unique_integer([:positive])}")
    nested = Path.join(root, "a/b")

    File.mkdir_p!(nested)

    on_exit(fn ->
      File.rm_rf(root)
    end)

    assert {:ok, safe} =
             WorkspaceGuard.confine_path("a/b/../file.txt",
               root: root,
               reject_parent_segments: false
             )

    assert safe == Path.join(root, "a/file.txt")
  end

  test "command_allowed?/2 rejects non-binary payloads" do
    assert {:error, "Invalid command"} = WorkspaceGuard.command_allowed?(123)
  end

  test "command_allowed?/2 rejects commands outside whitelist" do
    assert {:error, "Command not in whitelist"} =
             WorkspaceGuard.command_allowed?("curl https://example.com",
               workspace_root: File.cwd!()
             )
  end

  test "command_allowed?/2 accepts dynamic commands only when stack is detected" do
    root = Path.join("trash", "ws_guard_dynamic_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "mix.exs"), "defmodule Fixture.MixProject do\nend\n")

    on_exit(fn ->
      File.rm_rf(root)
    end)

    assert :ok = WorkspaceGuard.command_allowed?("mix format", workspace_root: root)
  end
end
