defmodule Pincer.Adapters.Tools.FileSystemTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.FileSystem

  defp anchor_for_line(output, line_number) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "|", parts: 2) do
        [anchor, _content] ->
          if String.starts_with?(anchor, "#{line_number}#"), do: anchor, else: nil

        _ ->
          nil
      end
    end)
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "pincer_file_system_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    {:ok, %{root: root, context: %{"workspace_path" => root}}}
  end

  test "write creates parent directories and persists content", %{root: root, context: context} do
    assert {:ok, message} =
             FileSystem.execute(
               %{"action" => "write", "path" => "notes/todo.txt", "content" => "ship it"},
               context
             )

    assert message =~ "Wrote"
    assert File.read!(Path.join(root, "notes/todo.txt")) == "ship it"
  end

  test "path plus content infers write for legacy tool calls", %{root: root, context: context} do
    assert {:ok, _message} =
             FileSystem.execute(
               %{"path" => "drafts/quick.txt", "content" => "legacy write"},
               context
             )

    assert File.read!(Path.join(root, "drafts/quick.txt")) == "legacy write"
  end

  test "malformed tool payload returns an error instead of crashing", %{context: context} do
    assert {:error, message} =
             FileSystem.execute(
               %{"path" => "docs/file.txt", "new_text" => "replacement only"},
               context
             )

    assert is_binary(message)
  end

  test "spec tells models to use workspace-relative paths" do
    spec = FileSystem.spec()

    assert spec.description =~ "workspace-relative paths"
    assert spec.description =~ "/app/workspaces/..."
    assert spec.parameters.properties.path.description =~ "Examples: '.', '.pincer'"
    assert spec.parameters.properties.path.description =~ "Do not use absolute container paths"
  end

  test "search scans directories recursively and returns relative path citations", %{
    context: context
  } do
    File.mkdir_p!(Path.join(context["workspace_path"], "lib/nested"))

    File.write!(
      Path.join(context["workspace_path"], "lib/app.txt"),
      "alpha\nwebhook timeout\nomega\n"
    )

    File.write!(
      Path.join(context["workspace_path"], "lib/nested/runbook.txt"),
      "retry storm\nwebhook timeout fix\n"
    )

    assert {:ok, result} =
             FileSystem.execute(
               %{"action" => "search", "path" => "lib", "query" => "webhook timeout"},
               context
             )

    decoded = Jason.decode!(result)
    assert decoded["total"] == 2
    paths_lines = Enum.map(decoded["matches"], &{&1["path"], &1["line"]})
    assert {"lib/app.txt", 2} in paths_lines
    assert {"lib/nested/runbook.txt", 2} in paths_lines
  end

  test "patch replaces a unique occurrence and writes the file back", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "config/runtime.txt")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "timeout=42\n")

    assert {:ok, result} =
             FileSystem.execute(
               %{
                 "action" => "patch",
                 "path" => "config/runtime.txt",
                 "old_text" => "42",
                 "new_text" => "60"
               },
               context
             )

    assert result =~ "Patched"
    assert File.read!(path) == "timeout=60\n"
  end

  test "patch rejects ambiguous replacements unless replace_all is true", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "config/repeated.txt")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "TODO one\nTODO two\n")

    assert {:error, message} =
             FileSystem.execute(
               %{
                 "action" => "patch",
                 "path" => "config/repeated.txt",
                 "old_text" => "TODO",
                 "new_text" => "DONE"
               },
               context
             )

    assert message =~ "multiple occurrences"

    assert {:ok, _result} =
             FileSystem.execute(
               %{
                 "action" => "patch",
                 "path" => "config/repeated.txt",
                 "old_text" => "TODO",
                 "new_text" => "DONE",
                 "replace_all" => true
               },
               context
             )

    assert File.read!(path) == "DONE one\nDONE two\n"
  end

  test "write blocks paths outside the workspace", %{context: context} do
    assert {:error, message} =
             FileSystem.execute(
               %{"action" => "write", "path" => "../../etc/passwd", "content" => "owned"},
               context
             )

    assert message =~ "Access denied" or message =~ "traversal"
  end

  test "append preserves existing content and appends new text", %{root: root, context: context} do
    path = Path.join(root, "logs/app.log")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "line one\n")

    assert {:ok, message} =
             FileSystem.execute(
               %{"action" => "append", "path" => "logs/app.log", "content" => "line two\n"},
               context
             )

    assert message =~ "Appended"
    assert File.read!(path) == "line one\nline two\n"
  end

  test "mkdir creates nested directories safely", %{root: root, context: context} do
    assert {:ok, message} =
             FileSystem.execute(
               %{"action" => "mkdir", "path" => "scratch/a/b/c"},
               context
             )

    assert message =~ "Created directory"
    assert File.dir?(Path.join(root, "scratch/a/b/c"))
  end

  test "delete_to_trash moves files into workspace trash", %{root: root, context: context} do
    path = Path.join(root, "notes/old.txt")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "legacy")

    assert {:ok, message} =
             FileSystem.execute(
               %{"action" => "delete_to_trash", "path" => "notes/old.txt"},
               context
             )

    assert message =~ ".trash/"
    refute File.exists?(path)
    assert File.exists?(Path.join(root, ".trash"))
  end

  test "delete_to_trash rejects the workspace root", %{context: context} do
    assert {:error, message} =
             FileSystem.execute(
               %{"action" => "delete_to_trash", "path" => "."},
               context
             )

    assert message =~ "workspace root"
  end

  test "copy duplicates a file without removing the source", %{root: root, context: context} do
    source = Path.join(root, "docs/source.txt")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "copy me")

    assert {:ok, message} =
             FileSystem.execute(
               %{
                 "action" => "copy",
                 "path" => "docs/source.txt",
                 "destination" => "docs/copied.txt"
               },
               context
             )

    assert message =~ "Copied"
    assert File.read!(source) == "copy me"
    assert File.read!(Path.join(root, "docs/copied.txt")) == "copy me"
  end

  test "move relocates a file within the workspace", %{root: root, context: context} do
    source = Path.join(root, "tmp/move-me.txt")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "moved")

    assert {:ok, message} =
             FileSystem.execute(
               %{
                 "action" => "move",
                 "path" => "tmp/move-me.txt",
                 "destination" => "archive/moved.txt"
               },
               context
             )

    assert message =~ "Moved"
    refute File.exists?(source)
    assert File.read!(Path.join(root, "archive/moved.txt")) == "moved"
  end

  test "copy rejects overwriting destination unless explicitly allowed", %{
    root: root,
    context: context
  } do
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, "docs/a.txt"), "source")
    File.write!(Path.join(root, "docs/b.txt"), "existing")

    assert {:error, message} =
             FileSystem.execute(
               %{
                 "action" => "copy",
                 "path" => "docs/a.txt",
                 "destination" => "docs/b.txt"
               },
               context
             )

    assert message =~ "already exists"

    assert {:ok, _message} =
             FileSystem.execute(
               %{
                 "action" => "copy",
                 "path" => "docs/a.txt",
                 "destination" => "docs/b.txt",
                 "overwrite" => true
               },
               context
             )

    assert File.read!(Path.join(root, "docs/b.txt")) == "source"
  end

  test "move rejects moving a directory into its own descendant", %{root: root, context: context} do
    source_dir = Path.join(root, "tree/root")
    File.mkdir_p!(source_dir)
    File.write!(Path.join(source_dir, "note.txt"), "hello")

    assert {:error, message} =
             FileSystem.execute(
               %{
                 "action" => "move",
                 "path" => "tree/root",
                 "destination" => "tree/root/nested/root"
               },
               context
             )

    assert message =~ "descendant"
    assert File.exists?(Path.join(source_dir, "note.txt"))
  end

  test "stat returns metadata for files", %{root: root, context: context} do
    path = Path.join(root, "meta/info.txt")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "12345")

    assert {:ok, output} =
             FileSystem.execute(
               %{"action" => "stat", "path" => "meta/info.txt"},
               context
             )

    assert %{
             "action" => "stat",
             "path" => "meta/info.txt",
             "type" => "regular",
             "size" => 5
           } = Jason.decode!(output)
  end

  test "read can return a specific line range", %{root: root, context: context} do
    path = Path.join(root, "notes/range.txt")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "one\ntwo\nthree\nfour\n")

    assert {:ok, output} =
             FileSystem.execute(
               %{
                 "action" => "read",
                 "path" => "notes/range.txt",
                 "from_line" => 2,
                 "line_count" => 2
               },
               context
             )

    assert output == "two\nthree\n"
  end

  test "search can filter by extension", %{context: context} do
    File.mkdir_p!(Path.join(context["workspace_path"], "docs"))
    File.write!(Path.join(context["workspace_path"], "docs/guide.md"), "Deploy timeout\n")
    File.write!(Path.join(context["workspace_path"], "docs/guide.txt"), "Deploy timeout\n")

    assert {:ok, output} =
             FileSystem.execute(
               %{
                 "action" => "search",
                 "path" => "docs",
                 "query" => "Deploy timeout",
                 "extension" => ".md"
               },
               context
             )

    decoded = Jason.decode!(output)
    paths = Enum.map(decoded["matches"], & &1["path"])
    assert "docs/guide.md" in paths
    refute "docs/guide.txt" in paths
  end

  test "list can traverse directories recursively", %{context: context} do
    root = context["workspace_path"]
    File.mkdir_p!(Path.join(root, "lib/nested"))
    File.write!(Path.join(root, "lib/app.ex"), "defmodule App do\nend\n")
    File.write!(Path.join(root, "lib/nested/tool.ex"), "defmodule Tool do\nend\n")

    assert {:ok, output} =
             FileSystem.execute(
               %{"action" => "list", "path" => "lib", "recursive" => true},
               context
             )

    assert output =~ "lib/app.ex"
    assert output =~ "lib/nested"
    assert output =~ "lib/nested/tool.ex"
  end

  test "read can return tail lines for logs", %{root: root, context: context} do
    path = Path.join(root, "logs/system.log")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "one\ntwo\nthree\nfour\n")

    assert {:ok, output} =
             FileSystem.execute(
               %{"action" => "read", "path" => "logs/system.log", "tail_lines" => 2},
               context
             )

    assert output == "three\nfour\n"
  end

  test "find locates files by glob and extension", %{context: context} do
    root = context["workspace_path"]
    File.mkdir_p!(Path.join(root, "apps/core"))
    File.mkdir_p!(Path.join(root, "apps/web"))
    File.write!(Path.join(root, "apps/core/app_test.exs"), "ok\n")
    File.write!(Path.join(root, "apps/web/app_test.exs"), "ok\n")
    File.write!(Path.join(root, "apps/web/app_test.txt"), "nope\n")

    assert {:ok, output} =
             FileSystem.execute(
               %{
                 "action" => "find",
                 "path" => "apps",
                 "glob" => "*test*",
                 "extension" => ".exs",
                 "type" => "file"
               },
               context
             )

    assert output =~ "apps/core/app_test.exs"
    assert output =~ "apps/web/app_test.exs"
    refute output =~ "apps/web/app_test.txt"
  end

  test "read can return hashlined content", %{root: root, context: context} do
    path = Path.join(root, "src/sample.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "alpha\n  beta()\n")

    assert {:ok, output} =
             FileSystem.execute(
               %{"action" => "read", "path" => "src/sample.ex", "hashline" => true},
               context
             )

    assert output =~ ~r/^1#[A-Z]{5}\|alpha/m
    assert output =~ ~r/^2#[A-Z]{5}\|  beta\(\)/m
  end

  test "spec recommends hashlined anchored edits for code changes" do
    spec = FileSystem.spec()

    assert spec.description =~ "Prefer read with hashline + anchored_edit for code edits"
    assert spec.parameters.properties.hashline.description =~ "Use before anchored_edit"
    assert spec.parameters.properties.edits.description =~ "replace"
  end

  test "spec keeps patch as exact literal fallback" do
    spec = FileSystem.spec()

    assert spec.parameters.properties.old_text.description =~ "exact literal replacement"
    assert spec.parameters.properties.new_text.description =~ "exact literal replacement"
  end

  test "anchored_edit replaces a line using only the anchor", %{root: root, context: context} do
    path = Path.join(root, "src/runtime.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "def run do\n  :ok\nend\n")

    assert {:ok, read_output} =
             FileSystem.execute(
               %{"action" => "read", "path" => "src/runtime.ex", "hashline" => true},
               context
             )

    anchor = anchor_for_line(read_output, 2)

    assert {:ok, message} =
             FileSystem.execute(
               %{
                 "action" => "anchored_edit",
                 "path" => "src/runtime.ex",
                 "edits" => [
                   %{"op" => "replace", "anchor" => anchor, "content" => "  :error"}
                 ]
               },
               context
             )

    assert message =~ "Applied 1 anchored edit"
    assert File.read!(path) == "def run do\n  :error\nend\n"
  end

  test "anchored_edit can insert after an anchor", %{root: root, context: context} do
    path = Path.join(root, "src/config.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "config :app\nconfig :db\n")

    assert {:ok, read_output} =
             FileSystem.execute(
               %{"action" => "read", "path" => "src/config.ex", "hashline" => true},
               context
             )

    anchor = anchor_for_line(read_output, 1)

    assert {:ok, _message} =
             FileSystem.execute(
               %{
                 "action" => "anchored_edit",
                 "path" => "src/config.ex",
                 "edits" => [
                   %{
                     "op" => "insert_after",
                     "anchor" => anchor,
                     "content" => "config :feature_flag"
                   }
                 ]
               },
               context
             )

    assert File.read!(path) == "config :app\nconfig :feature_flag\nconfig :db\n"
  end

  test "anchored_edit rejects stale anchors and preserves the file", %{
    root: root,
    context: context
  } do
    path = Path.join(root, "src/state.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "alpha\nbeta\n")

    assert {:ok, read_output} =
             FileSystem.execute(
               %{"action" => "read", "path" => "src/state.ex", "hashline" => true},
               context
             )

    anchor = anchor_for_line(read_output, 2)
    File.write!(path, "alpha\nbeta changed\n")

    assert {:error, message} =
             FileSystem.execute(
               %{
                 "action" => "anchored_edit",
                 "path" => "src/state.ex",
                 "edits" => [
                   %{"op" => "replace", "anchor" => anchor, "content" => "beta final"}
                 ]
               },
               context
             )

    assert message =~ "changed since last read"
    assert message =~ "2#"
    assert File.read!(path) == "alpha\nbeta changed\n"
  end

  test "supports both string and existing atom keys without interning arbitrary atoms", %{
    root: root,
    context: context
  } do
    File.write!(Path.join(root, "sample.txt"), "ok")
    unseen_arg = "unseen_fs_arg_#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             FileSystem.execute(
               %{"action" => "stat", "path" => "sample.txt", unseen_arg => "ignored"},
               context
             )

    assert {:ok, content} =
             FileSystem.execute(%{action: "read", path: "sample.txt"}, context)

    assert content =~ "ok"

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unseen_arg)
    end
  end

  describe "unzip Zip Slip confinement" do
    test "extracts valid archive inside workspace", %{root: root, context: context} do
      src_dir = Path.join(root, "src")
      File.mkdir_p!(src_dir)
      File.write!(Path.join(src_dir, "hello.txt"), "safe content")

      archive = Path.join(root, "valid.zip")

      {:ok, _} =
        :zip.create(String.to_charlist(archive), [{~c"nested/hello.txt", "safe content"}], [
          :memory
        ])
        |> then(fn {:ok, {_, bin}} ->
          File.write!(archive, bin)
          {:ok, archive}
        end)

      assert {:ok, msg} =
               FileSystem.execute(
                 %{"action" => "unzip", "path" => "valid.zip", "destination" => "out"},
                 context
               )

      assert msg =~ "Extracted 1 file(s)"
      assert File.read!(Path.join(root, "out/nested/hello.txt")) == "safe content"
    end

    test "blocks relative Zip Slip entries fail-closed without extracting anything", %{
      root: root,
      context: context
    } do
      evil_name = "pincer_zipslip_#{System.unique_integer([:positive])}.txt"
      evil_target = Path.join(Path.dirname(root), evil_name)
      rel_evil = "../../#{evil_name}"
      on_exit(fn -> File.rm(evil_target) end)

      {:ok, {_, bin}} =
        :zip.create(
          ~c"evil.zip",
          [{~c"good.txt", "good"}, {String.to_charlist(rel_evil), "pwned"}],
          [:memory]
        )

      File.write!(Path.join(root, "evil.zip"), bin)

      assert {:error, reason} =
               FileSystem.execute(
                 %{"action" => "unzip", "path" => "evil.zip", "destination" => "out"},
                 context
               )

      assert reason =~ "Zip Slip" or reason =~ "unsafe"
      refute File.exists?(evil_target)
      refute File.exists?(Path.join(root, "out/good.txt"))
    end

    test "blocks unzip into a symlinked directory escaping workspace", %{
      root: root,
      context: context
    } do
      outside =
        Path.join(System.tmp_dir!(), "pincer_zip_sym_#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)

      File.ln_s!(outside, Path.join(root, "escape_dir"))

      {:ok, {_, bin}} = :zip.create(~c"valid.zip", [{~c"inner.txt", "hello"}], [:memory])
      File.write!(Path.join(root, "valid.zip"), bin)

      assert {:error, reason} =
               FileSystem.execute(
                 %{"action" => "unzip", "path" => "valid.zip", "destination" => "escape_dir/sub"},
                 context
               )

      assert reason =~ "Access denied" or reason =~ "outside"
      refute File.exists?(Path.join(outside, "sub/inner.txt"))
    end

    test "blocks absolute path entries and backslash traversal entries", %{
      root: root,
      context: context
    } do
      abs_target =
        Path.join(
          System.tmp_dir!(),
          "pincer_zipslip_abs_#{System.unique_integer([:positive])}.txt"
        )

      on_exit(fn -> File.rm(abs_target) end)

      {:ok, {_, abs_bin}} =
        :zip.create(~c"abs.zip", [{String.to_charlist(abs_target), "pwned"}], [:memory])

      File.write!(Path.join(root, "abs.zip"), abs_bin)

      assert {:error, _} =
               FileSystem.execute(
                 %{"action" => "unzip", "path" => "abs.zip", "destination" => "out_abs"},
                 context
               )

      refute File.exists?(abs_target)

      {:ok, {_, win_bin}} =
        :zip.create(~c"win.zip", [{~c"..\\evil_win.txt", "pwned"}], [:memory])

      File.write!(Path.join(root, "win.zip"), win_bin)

      assert {:error, _} =
               FileSystem.execute(
                 %{"action" => "unzip", "path" => "win.zip", "destination" => "out_win"},
                 context
               )

      refute File.exists?(Path.expand(Path.join(root, "../evil_win.txt")))
    end
  end

  describe "additional submodule coverage and security invariants" do
    test "zip creates archive confined to workspace and rejects traversal destination", %{
      root: root,
      context: context
    } do
      File.mkdir_p!(Path.join(root, "bundle/sub"))
      File.write!(Path.join(root, "bundle/a.txt"), "alpha")
      File.write!(Path.join(root, "bundle/sub/b.txt"), "beta")

      assert {:error, reason} =
               FileSystem.execute(
                 %{"action" => "zip", "path" => "bundle", "destination" => "../../escape.zip"},
                 context
               )

      assert reason =~ "traversal" or reason =~ "Access denied"

      assert {:ok, msg} =
               FileSystem.execute(
                 %{"action" => "zip", "path" => "bundle", "destination" => "archives/out"},
                 context
               )

      assert msg =~ "archives/out.zip"
      assert msg =~ "2 file(s)"
      assert File.exists?(Path.join(root, "archives/out.zip"))
    end

    test "send_to_channel validates session context and broadcasts regular files", %{
      root: root,
      context: context
    } do
      File.mkdir_p!(Path.join(root, "outbox"))
      File.write!(Path.join(root, "outbox/report.txt"), "summary")

      assert {:error, no_session_msg} =
               FileSystem.execute(
                 %{"action" => "send_to_channel", "path" => "outbox/report.txt"},
                 context
               )

      assert no_session_msg =~ "session context"

      session_id = "test_fs_send_#{System.unique_integer([:positive])}"
      Pincer.Infra.PubSub.subscribe("session:#{session_id}")

      assert {:error, dir_msg} =
               FileSystem.execute(
                 %{"action" => "send_to_channel", "path" => "outbox"},
                 Map.put(context, "session_id", session_id)
               )

      assert dir_msg =~ "Cannot send a directory"

      assert {:ok, sent_msg} =
               FileSystem.execute(
                 %{
                   "action" => "send_to_channel",
                   "path" => "outbox/report.txt",
                   "caption" => "Here is the report"
                 },
                 Map.put(context, "session_id", session_id)
               )

      assert sent_msg =~ "Sending 'outbox/report.txt'"

      expected_path = Path.join(root, "outbox/report.txt")
      assert_receive {:agent_file, ^expected_path, %{caption: "Here is the report"}}
    end

    test "anchored_edit supports range replace with end_anchor, insert_before, and LINE# prefix",
         %{
           root: root,
           context: context
         } do
      path = Path.join(root, "src/multi.ex")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "one\ntwo\nthree\nfour\n")

      assert {:ok, read_output} =
               FileSystem.execute(
                 %{"action" => "read", "path" => "src/multi.ex", "hashline" => true},
                 context
               )

      a1 = anchor_for_line(read_output, 1)
      a2 = anchor_for_line(read_output, 2)
      a3 = anchor_for_line(read_output, 3)

      assert {:ok, msg} =
               FileSystem.execute(
                 %{
                   "action" => "anchored_edit",
                   "path" => "src/multi.ex",
                   "edits" => [
                     %{"op" => "insert_before", "anchor" => "LINE#" <> a1, "content" => "zero"},
                     %{
                       "op" => "replace",
                       "anchor" => a2,
                       "end_anchor" => a3,
                       "content" => "two-and-three"
                     }
                   ]
                 },
                 context
               )

      assert msg =~ "Applied 2 anchored edit"
      assert File.read!(path) == "zero\none\ntwo-and-three\nfour\n"
    end

    test "delete_to_trash rejects items already inside .trash and copy/move block null bytes in destination",
         %{
           root: root,
           context: context
         } do
      File.write!(Path.join(root, "item.txt"), "x")

      assert {:ok, _} =
               FileSystem.execute(
                 %{"action" => "delete_to_trash", "path" => "item.txt"},
                 context
               )

      [trashed] = File.ls!(Path.join(root, ".trash"))

      assert {:error, trash_err} =
               FileSystem.execute(
                 %{"action" => "delete_to_trash", "path" => ".trash/#{trashed}"},
                 context
               )

      assert trash_err =~ "already inside the workspace trash"

      File.write!(Path.join(root, "src.txt"), "data")

      for action <- ["copy", "move"] do
        assert {:error, null_err} =
                 FileSystem.execute(
                   %{"action" => action, "path" => "src.txt", "destination" => "bad\0dest.txt"},
                   context
                 )

        assert null_err =~ "null"
      end
    end

    test "find and search preserve traversal order when truncated by max_results", %{
      root: root,
      context: context
    } do
      File.mkdir_p!(Path.join(root, "ordered"))
      File.write!(Path.join(root, "ordered/a.txt"), "match 1\nmatch 2\n")
      File.write!(Path.join(root, "ordered/b.txt"), "match 3\n")
      File.write!(Path.join(root, "ordered/c.txt"), "match 4\n")

      assert {:ok, find_json} =
               FileSystem.execute(
                 %{"action" => "find", "path" => "ordered", "type" => "file", "max_results" => 2},
                 context
               )

      find_decoded = Jason.decode!(find_json)
      assert find_decoded["truncated"] == true
      assert find_decoded["entries"] == ["ordered/a.txt", "ordered/b.txt"]

      assert {:ok, search_json} =
               FileSystem.execute(
                 %{
                   "action" => "search",
                   "path" => "ordered",
                   "query" => "match",
                   "max_results" => 2
                 },
                 context
               )

      search_decoded = Jason.decode!(search_json)
      assert search_decoded["truncated"] == true

      assert Enum.map(search_decoded["matches"], &{&1["path"], &1["line"]}) == [
               {"ordered/a.txt", 1},
               {"ordered/a.txt", 2}
             ]
    end
  end
end
