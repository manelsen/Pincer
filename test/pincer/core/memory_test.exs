defmodule Pincer.Core.MemoryTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Memory

  setup do
    tmp = Path.join(System.tmp_dir!(), "pincer_memory_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    {:ok, %{tmp: tmp}}
  end

  test "append_history/2 writes structured entry to HISTORY.md", %{tmp: tmp} do
    history_path = Path.join(tmp, "HISTORY.md")

    assert {:ok, %{status: :appended, digest: digest}} =
             Memory.append_history("Fixed webhook callback crash",
               session_id: "telegram_100",
               history_path: history_path
             )

    assert digest =~ ~r/^[a-f0-9]{12}$/

    history = File.read!(history_path)
    assert history =~ "<!-- PINCER_HISTORY digest=#{digest}"
    assert history =~ "session=telegram_100"
    assert history =~ "Fixed webhook callback crash"
  end

  test "append_history/2 is idempotent for same session and content", %{tmp: tmp} do
    history_path = Path.join(tmp, "HISTORY.md")

    assert {:ok, %{status: :appended, digest: digest}} =
             Memory.append_history("Session summary",
               session_id: "s1",
               history_path: history_path
             )

    assert {:ok, %{status: :noop, digest: ^digest}} =
             Memory.append_history("Session summary",
               session_id: "s1",
               history_path: history_path
             )

    history = File.read!(history_path)

    assert Regex.scan(~r/<!-- PINCER_HISTORY digest=/, history) |> length() == 1
  end

  test "consolidate_window/1 keeps only N newest entries and rolls old ones into MEMORY.md", %{
    tmp: tmp
  } do
    history_path = Path.join(tmp, "HISTORY.md")
    memory_path = Path.join(tmp, "MEMORY.md")

    assert {:ok, %{digest: digest1}} =
             Memory.append_history("first event", session_id: "s1", history_path: history_path)

    assert {:ok, %{digest: digest2}} =
             Memory.append_history("second event", session_id: "s2", history_path: history_path)

    assert {:ok, %{digest: digest3}} =
             Memory.append_history("third event", session_id: "s3", history_path: history_path)

    assert {:ok, %{status: :consolidated, moved: 1, kept: 2}} =
             Memory.consolidate_window(
               history_path: history_path,
               memory_path: memory_path,
               window_size: 2
             )

    history = File.read!(history_path)
    assert history =~ digest2
    assert history =~ digest3
    refute history =~ digest1
    assert Regex.scan(~r/<!-- PINCER_HISTORY digest=/, history) |> length() == 2

    memory = File.read!(memory_path)
    assert memory =~ "[HIST:#{digest1}]"
    assert memory =~ "first event"

    assert {:ok, %{status: :noop}} =
             Memory.consolidate_window(
               history_path: history_path,
               memory_path: memory_path,
               window_size: 2
             )

    memory_after_second_run = File.read!(memory_path)
    assert Regex.scan(~r/\[HIST:#{digest1}\]/, memory_after_second_run) |> length() == 1
  end
end
