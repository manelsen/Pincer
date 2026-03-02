defmodule Pincer.CLI.HistoryTest do
  use ExUnit.Case, async: true

  alias Pincer.CLI.History

  setup do
    tmp_root =
      Path.join(System.tmp_dir!(), "pincer_cli_history_#{System.unique_integer([:positive])}")

    path = Path.join(tmp_root, "history.log")
    on_exit(fn -> File.rm_rf(tmp_root) end)
    {:ok, history_path: path}
  end

  test "recent/2 returns empty list when history file does not exist", %{history_path: path} do
    assert [] == History.recent(10, path: path)
  end

  test "append/2 persists entries and recent/2 returns the latest in chronological order", %{
    history_path: path
  } do
    assert :ok == History.append("first", path: path)
    assert :ok == History.append("second", path: path)
    assert :ok == History.append("third", path: path)

    assert ["first", "second", "third"] == History.recent(10, path: path)
    assert ["second", "third"] == History.recent(2, path: path)
  end

  test "clear/1 deletes persisted history", %{history_path: path} do
    assert :ok == History.append("kept", path: path)
    assert ["kept"] == History.recent(10, path: path)

    assert :ok == History.clear(path: path)
    assert [] == History.recent(10, path: path)
  end
end
