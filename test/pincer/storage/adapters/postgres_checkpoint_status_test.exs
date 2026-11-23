defmodule Pincer.Storage.Adapters.PostgresCheckpointStatusTest do
  use ExUnit.Case, async: false

  alias Pincer.Infra.Repo
  alias Pincer.Storage.Adapters.Postgres

  setup do
    Application.ensure_all_started(:pincer)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "load_checkpoint/2 honors the status filter" do
    session_id = "pg-chk-filter-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Postgres.save_checkpoint(session_id, %{
               status: "running",
               history_snapshot: :erlang.term_to_binary([]),
               step_count: 1,
               metadata: %{"phase" => "live"}
             })

    assert {:ok, _} =
             Postgres.save_checkpoint(session_id, %{
               status: "finished",
               history_snapshot: :erlang.term_to_binary([]),
               step_count: 2,
               metadata: %{"phase" => "done", "result" => "all clear"}
             })

    # Default filter only consults running/paused. Saving "finished" demoted the
    # previous running row to paused, so that is the latest visible default row.
    assert {:ok, default_row} = Postgres.load_checkpoint(session_id)
    assert default_row.status == "paused"
    assert default_row.metadata == %{"phase" => "live"}

    assert {:ok, finished} = Postgres.load_checkpoint(session_id, status: ["finished"])
    assert finished.status == "finished"
    assert finished.step_count == 2
    assert finished.metadata == %{"phase" => "done", "result" => "all clear"}

    assert {:ok, paused} =
             Postgres.load_checkpoint(session_id, status: ["running", "paused"])

    assert paused.status == "paused"

    assert {:error, :not_found} = Postgres.load_checkpoint(session_id, status: ["failed"])
    assert {:error, :not_found} = Postgres.load_checkpoint(session_id, status: ["interrupted"])
  end

  test "load_checkpoint/2 status filter selects rows across non-active statuses" do
    interrupted_session = "pg-chk-int-#{System.unique_integer([:positive])}"
    failed_session = "pg-chk-fail-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Postgres.save_checkpoint(interrupted_session, %{
               status: "interrupted",
               history_snapshot: :erlang.term_to_binary([]),
               step_count: 3,
               metadata: %{"reason" => "boot"}
             })

    assert {:ok, _} =
             Postgres.save_checkpoint(failed_session, %{
               status: "failed",
               history_snapshot: :erlang.term_to_binary([]),
               step_count: 4,
               metadata: %{"error" => "boom"}
             })

    assert {:ok, interrupted} =
             Postgres.load_checkpoint(interrupted_session, status: ["interrupted", "failed"])

    assert interrupted.status == "interrupted"
    assert interrupted.step_count == 3

    assert {:ok, failed} =
             Postgres.load_checkpoint(failed_session, status: ["interrupted", "failed"])

    assert failed.status == "failed"
    assert failed.step_count == 4
  end
end
