defmodule Pincer.Core.Memory.CuratedMemoryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Memory.CuratedMemory

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "pincer_curated_#{System.unique_integer([:positive])}")

    File.mkdir_p!(AgentPaths.pincer_dir(workspace))
    on_exit(fn -> File.rm_rf!(workspace) end)

    {:ok, workspace: workspace}
  end

  describe "write/4" do
    test "writes content below the cap unchanged and reports bytes written", %{
      workspace: workspace
    } do
      content = "# Memory\n\n- one fact\n- another fact\n"

      assert {:ok, written} =
               CuratedMemory.write(workspace, :memory, content, max_chars: 1_000)

      assert written == byte_size(content)
      assert File.read!(AgentPaths.memory_path(workspace)) == content
    end

    test "truncates over-cap content at a line boundary and logs", %{workspace: workspace} do
      lines = for index <- 1..50, do: "line #{index} #{String.duplicate("x", 30)}"
      content = Enum.join(lines, "\n") <> "\n"

      log =
        capture_log(fn ->
          assert {:ok, written} =
                   CuratedMemory.write(workspace, :memory, content, max_chars: 200)

          stored = File.read!(AgentPaths.memory_path(workspace))

          assert written == byte_size(stored)
          assert byte_size(stored) <= 200
          assert byte_size(stored) < byte_size(content)
          assert stored != ""

          stored_lines = String.split(stored, "\n", trim: true)
          assert Enum.all?(stored_lines, &(&1 in lines))
          refute stored =~ "line 50 "
        end)

      assert log =~ "truncat"
    end

    test "applies the configured default caps for memory and user files", %{
      workspace: workspace
    } do
      long =
        Enum.map_join(1..400, "\n", fn index -> "- fact #{index} #{String.duplicate("z", 40)}" end)

      assert {:ok, memory_bytes} = CuratedMemory.write(workspace, :memory, long)
      assert {:ok, user_bytes} = CuratedMemory.write(workspace, :user, long)

      assert memory_bytes <= 4_000
      assert user_bytes <= 2_500
      assert byte_size(File.read!(AgentPaths.memory_path(workspace))) <= 4_000
      assert byte_size(File.read!(AgentPaths.user_path(workspace))) <= 2_500
    end
  end

  describe "read/3" do
    test "returns the whole file when it fits the cap", %{workspace: workspace} do
      content = "# User\n\n## Learned User Memory\n- prefers direct answers\n"
      File.write!(AgentPaths.user_path(workspace), content)

      assert CuratedMemory.read(workspace, :user, max_chars: 1_000) == content
    end

    test "bounds an oversized file at a line boundary with an explicit marker", %{
      workspace: workspace
    } do
      lines = for index <- 1..20, do: "HEAD #{index} #{String.duplicate("y", 20)}"
      File.write!(AgentPaths.memory_path(workspace), Enum.join(lines, "\n") <> "\nTAIL_SECRET")

      bounded = CuratedMemory.read(workspace, :memory, max_chars: 100)

      assert byte_size(bounded) <= 100
      assert bounded =~ "HEAD 1 "
      refute bounded =~ "TAIL_SECRET"
      assert String.ends_with?(bounded, "[truncated]")

      kept_lines =
        bounded
        |> String.split("\n")
        |> Enum.reject(&(&1 == "[truncated]"))

      assert Enum.all?(kept_lines, &(&1 in lines))
    end

    test "returns an empty string when the file is absent", %{workspace: workspace} do
      assert CuratedMemory.read(workspace, :memory) == ""
      assert CuratedMemory.read(workspace, :user) == ""
    end
  end
end
