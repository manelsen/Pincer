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
end
