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

  describe "validate_command/2 and command_allowed?/2 unified shell policy" do
    test "validates du -sh variants and rejects traversal" do
      root = Path.join("trash", "ws_guard_du_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "sub/dir"))

      on_exit(fn -> File.rm_rf(root) end)

      assert {:ok, "du -sh"} = WorkspaceGuard.validate_command("du   -sh", workspace_root: root)
      assert :ok = WorkspaceGuard.command_allowed?("du -sh", workspace_root: root)

      assert {:ok, "du -sh sub/dir"} =
               WorkspaceGuard.validate_command("du -sh sub/dir", workspace_root: root)

      assert :ok = WorkspaceGuard.command_allowed?("du -sh sub/dir", workspace_root: root)

      assert {:error, "Unsafe path argument"} =
               WorkspaceGuard.validate_command("du -sh ../outside", workspace_root: root)

      assert {:error, "Unsafe path argument"} =
               WorkspaceGuard.command_allowed?("du -sh ../outside", workspace_root: root)
    end

    test "blocks dangerous find flags and allows read-only find flags" do
      root = File.cwd!()

      assert {:ok, "find . -maxdepth 2"} =
               WorkspaceGuard.validate_command("find . -maxdepth 2", workspace_root: root)

      assert :ok = WorkspaceGuard.command_allowed?("find . -maxdepth 2", workspace_root: root)

      assert {:error, "Dangerous find flag requires approval"} =
               WorkspaceGuard.command_allowed?("find . -delete", workspace_root: root)

      assert {:error, _reason} =
               WorkspaceGuard.command_allowed?("find . -exec sh -c id \\;", workspace_root: root)
    end

    test "blocks dangerous git log flags and allows standard git log" do
      root = File.cwd!()

      assert {:ok, "git log -n 5"} =
               WorkspaceGuard.validate_command("git log -n 5", workspace_root: root)

      assert :ok = WorkspaceGuard.command_allowed?("git log -n 5", workspace_root: root)

      assert {:error, "Dangerous git log flag requires approval"} =
               WorkspaceGuard.command_allowed?("git log --output=/tmp/x", workspace_root: root)
    end

    test "requires approval for grep" do
      assert {:error, "Grep requires approval"} =
               WorkspaceGuard.validate_command("grep foo bar", workspace_root: File.cwd!())

      assert {:error, "Grep requires approval"} =
               WorkspaceGuard.command_allowed?("grep foo bar", workspace_root: File.cwd!())
    end

    test "rejects path traversal and metacharacters across commands" do
      root = File.cwd!()

      for cmd <- [
            "cat ../outside",
            "ls ../outside",
            "ls /etc",
            "cat ~/.ssh/config",
            "cat C:\\Windows\\win.ini",
            "ls; id",
            "ls && id",
            "ls | cat",
            "ls $(id)",
            "ls `id`",
            "ls > out.txt",
            "ls\nid",
            "ls \\\n-a"
          ] do
        assert {:error, _reason} = WorkspaceGuard.command_allowed?(cmd, workspace_root: root)
      end
    end

    test "defaults workspace_restrict to true and allows explicit opt-out for symlink confinement" do
      root = Path.join("trash", "ws_guard_restrict_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      link_path = Path.join(root, "etc_passwd_link")
      :ok = File.ln_s("/etc/passwd", link_path)

      on_exit(fn -> File.rm_rf(root) end)

      # Default (workspace_restrict: true) blocks symlink escaping workspace_root
      assert {:error, "Unsafe path argument"} =
               WorkspaceGuard.command_allowed?("cat etc_passwd_link", workspace_root: root)

      # Explicit workspace_restrict: false skips workspace confinement check on relative path
      assert {:ok, "cat etc_passwd_link"} =
               WorkspaceGuard.validate_command("cat etc_passwd_link",
                 workspace_root: root,
                 workspace_restrict: false
               )
    end

    test "validates dynamic CommandProfile prefixes with safe args and blocks unsafe args" do
      root = Path.join("trash", "ws_guard_dyn_args_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      File.write!(Path.join(root, "package.json"), ~s({"scripts":{"lint":"eslint ."}}))

      on_exit(fn -> File.rm_rf(root) end)

      assert {:ok, "npm run lint"} =
               WorkspaceGuard.validate_command("npm run lint", workspace_root: root)

      assert {:error, "Arguments contain unsafe path patterns"} =
               WorkspaceGuard.validate_command("npm run lint /etc/passwd", workspace_root: root)
    end
  end

  describe "pdftotext command validation" do
    test "allows pdftotext to stdout with relative path and numeric page ranges" do
      root = Path.join("trash", "ws_guard_pdf_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "docs"))
      File.write!(Path.join(root, "docs/sample.pdf"), "%PDF-1.4")

      on_exit(fn -> File.rm_rf(root) end)

      assert {:ok, "pdftotext docs/sample.pdf -"} =
               WorkspaceGuard.validate_command("pdftotext docs/sample.pdf -",
                 workspace_root: root
               )

      assert :ok =
               WorkspaceGuard.command_allowed?("pdftotext docs/sample.pdf -",
                 workspace_root: root
               )

      assert {:ok, "pdftotext -f 1 -l 5 docs/sample.pdf -"} =
               WorkspaceGuard.validate_command("pdftotext -f 1 -l 5 docs/sample.pdf -",
                 workspace_root: root
               )

      assert :ok =
               WorkspaceGuard.command_allowed?("pdftotext -f 3 -l 3 docs/sample.pdf -",
                 workspace_root: root
               )
    end

    test "blocks pdftotext without trailing stdout dash, with non-numeric ranges, or unsafe paths" do
      root = Path.join("trash", "ws_guard_pdf_bad_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      :ok = File.ln_s("/etc/passwd", Path.join(root, "escaping.pdf"))

      on_exit(fn -> File.rm_rf(root) end)

      for bad_cmd <- [
            "pdftotext docs/sample.pdf",
            "pdftotext docs/sample.pdf out.txt",
            "pdftotext -f 1 -l 5 docs/sample.pdf out.txt",
            "pdftotext -f 1 docs/sample.pdf -",
            "pdftotext -f abc -l 5 docs/sample.pdf -",
            "pdftotext -f 1 -l 5x docs/sample.pdf -",
            "pdftotext -f -1 -l 5 docs/sample.pdf -",
            "pdftotext -raw docs/sample.pdf -",
            "pdftotext -raw -",
            "pdftotext - -",
            "pdftotext ../outside.pdf -",
            "pdftotext /etc/passwd -",
            "pdftotext ~/secret.pdf -",
            "pdftotext escaping.pdf -",
            "pdftotext docs/sample.pdf -; id"
          ] do
        assert {:error, _reason} =
                 WorkspaceGuard.validate_command(bad_cmd, workspace_root: root),
               "Expected #{inspect(bad_cmd)} to be rejected"
      end
    end
  end
end
