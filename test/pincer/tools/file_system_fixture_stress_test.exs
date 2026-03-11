defmodule Pincer.Adapters.Tools.FileSystemFixtureStressTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.FileSystem

  @fixture_root Path.expand("test/fixtures/file_system_workspace", File.cwd!())

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "pincer_file_system_fixture_#{System.unique_integer([:positive])}"
      )

    File.cp_r!(@fixture_root, root)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    {:ok, %{root: root, context: %{"workspace_path" => root}}}
  end

  test "fixture workspace supports discovery and read flows", %{context: context} do
    assert {:ok, find_output} =
             FileSystem.execute(
               %{"action" => "find", "path" => ".", "glob" => "*.md", "type" => "file"},
               context
             )

    assert find_output =~ "README.md"
    assert find_output =~ "docs/runbook.md"

    assert {:ok, search_output} =
             FileSystem.execute(
               %{
                 "action" => "search",
                 "path" => "docs",
                 "query" => "webhook timeout",
                 "extension" => ".md"
               },
               context
             )

    assert search_output =~ "docs/runbook.md:5"

    assert {:ok, stat_output} =
             FileSystem.execute(
               %{"action" => "stat", "path" => "config/runtime.exs"},
               context
             )

    assert stat_output =~ "path: config/runtime.exs"
    assert stat_output =~ "type: regular"

    assert {:ok, read_output} =
             FileSystem.execute(
               %{
                 "action" => "read",
                 "path" => "lib/pipeline.ex",
                 "from_line" => 1,
                 "line_count" => 6
               },
               context
             )

    assert read_output =~ "defmodule Fixture.Pipeline do"
    assert read_output =~ "def run(input) do"
  end

  test "fixture workspace supports exact patch and anchored edits", %{
    root: root,
    context: context
  } do
    assert {:ok, _message} =
             FileSystem.execute(
               %{
                 "action" => "patch",
                 "path" => "config/runtime.exs",
                 "old_text" => "hashline_editor: false",
                 "new_text" => "hashline_editor: true"
               },
               context
             )

    assert File.read!(Path.join(root, "config/runtime.exs")) =~ "hashline_editor: true"

    assert {:ok, read_output} =
             FileSystem.execute(
               %{"action" => "read", "path" => "lib/pipeline.ex", "hashline" => true},
               context
             )

    normalize_anchor = anchor_for_match(read_output, ~r/^\s*def normalize\(input\) do$/)
    enrich_anchor = anchor_for_match(read_output, ~r/"enriched:" <> input/)

    assert {:ok, _message} =
             FileSystem.execute(
               %{
                 "action" => "anchored_edit",
                 "path" => "lib/pipeline.ex",
                 "edits" => [
                   %{
                     "op" => "insert_after",
                     "anchor" => normalize_anchor,
                     "content" => "    |> String.replace(\"-\", \"_\")"
                   },
                   %{
                     "op" => "replace",
                     "anchor" => enrich_anchor,
                     "content" => ~s("decorated:" <> input)
                   }
                 ]
               },
               context
             )

    updated = File.read!(Path.join(root, "lib/pipeline.ex"))
    assert updated =~ "|> String.replace(\"-\", \"_\")"
    assert updated =~ "\"decorated:\" <> input"
  end

  test "anchored_edit stress applies many edits and rejects stale follow-up batch", %{
    root: root,
    context: context
  } do
    assert {:ok, read_output} =
             FileSystem.execute(
               %{"action" => "read", "path" => "lib/pipeline.ex", "hashline" => true},
               context
             )

    line_pairs =
      read_output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        [anchor, content] = String.split(line, "|", parts: 2)
        {anchor, content}
      end)

    step_edits =
      line_pairs
      |> Enum.filter(fn {_anchor, content} -> String.starts_with?(content, "  def step_") end)
      |> Enum.take(12)
      |> Enum.map(fn {anchor, content} ->
        [left, right] = String.split(content, ", do: ", parts: 2)
        new_right = String.replace(right, "value + ", "value * ")
        %{"op" => "replace", "anchor" => anchor, "content" => left <> ", do: " <> new_right}
      end)

    telemetry_anchor =
      anchor_for_match(read_output, ~r/^\s*def telemetry_metadata\(session_id\) do$/)

    edits =
      step_edits ++
        [
          %{
            "op" => "insert_after",
            "anchor" => telemetry_anchor,
            "content" => "    |> Map.put(:instrumented, true)"
          }
        ]

    assert {:ok, message} =
             FileSystem.execute(
               %{"action" => "anchored_edit", "path" => "lib/pipeline.ex", "edits" => edits},
               context
             )

    assert message =~ "Applied 13 anchored edit"

    updated = File.read!(Path.join(root, "lib/pipeline.ex"))
    assert updated =~ "def step_01(value), do: value * 1"
    assert updated =~ "def step_12(value), do: value * 12"
    assert updated =~ "|> Map.put(:instrumented, true)"
    assert updated =~ "def step_40(value), do: value + 40"

    stale_batch = Enum.take(edits, 2)

    assert {:error, stale_message} =
             FileSystem.execute(
               %{
                 "action" => "anchored_edit",
                 "path" => "lib/pipeline.ex",
                 "edits" => stale_batch
               },
               context
             )

    assert stale_message =~ "changed since last read"
    assert stale_message =~ ">>>"

    unchanged_after_reject = File.read!(Path.join(root, "lib/pipeline.ex"))
    assert unchanged_after_reject == updated
  end

  defp anchor_for_match(hashline_output, matcher) do
    hashline_output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "|", parts: 2) do
        [anchor, content] ->
          case matcher do
            value when is_binary(value) ->
              if content == value, do: anchor, else: nil

            %Regex{} = regex ->
              if String.match?(content, regex), do: anchor, else: nil
          end

        _ ->
          nil
      end
    end)
    |> case do
      nil -> flunk("anchor not found for #{inspect(matcher)}")
      anchor -> anchor
    end
  end
end
