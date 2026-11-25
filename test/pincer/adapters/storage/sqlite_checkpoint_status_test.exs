defmodule Pincer.Adapters.Storage.SQLiteCheckpointStatusTest do
  use ExUnit.Case, async: false

  alias Pincer.Infra.SQLite
  alias Pincer.Adapters.Storage.SQLite, as: SQLiteStorage

  setup do
    prev_server = Application.get_env(:pincer, :sqlite_server)
    db_pid = start_supervised!({SQLite, name: nil, db_path: ":memory:"})
    Application.put_env(:pincer, :sqlite_server, db_pid)

    on_exit(fn ->
      case prev_server do
        nil -> Application.delete_env(:pincer, :sqlite_server)
        value -> Application.put_env(:pincer, :sqlite_server, value)
      end
    end)

    {:ok, db: db_pid}
  end

  test "load_checkpoint/2 honors the status filter" do
    session_id = "chk-filter-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             SQLiteStorage.save_checkpoint(session_id, %{
               status: "running",
               history_snapshot: :erlang.term_to_binary([]),
               step_count: 1,
               metadata: %{"phase" => "live"}
             })

    assert {:ok, _} =
             SQLiteStorage.save_checkpoint(session_id, %{
               status: "finished",
               history_snapshot: :erlang.term_to_binary([]),
               step_count: 2,
               metadata: %{"phase" => "done", "result" => "all clear"}
             })

    # Default filter only consults running/paused. Saving "finished" demoted the
    # previous running row to paused, so that is the latest visible default row.
    assert {:ok, default_row} = SQLiteStorage.load_checkpoint(session_id)
    assert default_row.status == "paused"
    assert default_row.metadata == %{"phase" => "live"}

    assert {:ok, finished} = SQLiteStorage.load_checkpoint(session_id, status: ["finished"])
    assert finished.status == "finished"
    assert finished.step_count == 2
    assert finished.metadata == %{"phase" => "done", "result" => "all clear"}

    assert {:ok, paused} =
             SQLiteStorage.load_checkpoint(session_id, status: ["running", "paused"])

    assert paused.status == "paused"

    assert {:error, :not_found} = SQLiteStorage.load_checkpoint(session_id, status: ["failed"])

    assert {:error, :not_found} =
             SQLiteStorage.load_checkpoint(session_id, status: ["interrupted"])
  end

  test "load_checkpoint/2 status filter selects the newest checkpoint across statuses" do
    session_id = "chk-order-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             SQLiteStorage.save_checkpoint(session_id, %{
               status: "interrupted",
               history_snapshot: :erlang.term_to_binary([]),
               step_count: 3,
               metadata: %{"reason" => "boot"}
             })

    assert {:ok, _} =
             SQLiteStorage.save_checkpoint(session_id, %{
               status: "failed",
               history_snapshot: :erlang.term_to_binary([]),
               step_count: 4,
               metadata: %{"error" => "boom"}
             })

    assert {:ok, failed} =
             SQLiteStorage.load_checkpoint(session_id, status: ["interrupted", "failed"])

    assert failed.status == "failed"
    assert failed.step_count == 4
  end
end
