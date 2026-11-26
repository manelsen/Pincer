defmodule Pincer.Test.Support.SyncHelpersTest do
  use ExUnit.Case, async: true

  alias Pincer.Test.Support.SyncHelpers

  test "eventually/2 waits for truthy condition and returns its value" do
    agent = start_supervised!({Agent, fn -> 0 end})
    parent = self()

    spawn(fn ->
      Agent.update(agent, fn _ -> 42 end)
      send(parent, :updated)
    end)

    assert_receive :updated, 500
    assert SyncHelpers.eventually(fn -> Agent.get(agent, & &1) == 42 and :ok end) == :ok
  end

  test "eventually/2 supports ExUnit assertion blocks and fails on timeout" do
    assert_raise ExUnit.AssertionError, ~r/custom timeout/, fn ->
      SyncHelpers.eventually(
        fn ->
          assert 1 == 2
        end,
        timeout: 20,
        interval: 5,
        message: "custom timeout"
      )
    end
  end

  test "flush_mailbox/0 drains queued messages in order" do
    SyncHelpers.flush_mailbox()
    send(self(), :first)
    send(self(), :second)

    assert SyncHelpers.flush_mailbox() == [:first, :second]
    assert SyncHelpers.flush_mailbox() == []
  end

  test "temp_sqlite_path!/1 creates a directory that is cleaned up on exit" do
    path = SyncHelpers.temp_sqlite_path!("sync_helper_db")
    assert String.ends_with?(path, "pincer.db")
    assert File.dir?(Path.dirname(path))
  end

  test "ensure_started!/1 is idempotent when a named process is already running" do
    name = :"sync_helpers_agent_#{System.unique_integer([:positive])}"
    pid1 = SyncHelpers.ensure_started!({Agent, fn -> :ok end})
    assert is_pid(pid1)

    pid2 = SyncHelpers.ensure_started!(Supervisor.child_spec({Agent, fn -> :ok end}, id: name))
    assert is_pid(pid2)

    assert is_pid(SyncHelpers.ensure_started!(Pincer.Infra.PubSub))
    assert is_pid(SyncHelpers.ensure_started!({Pincer.Infra.SQLite, db_path: ":memory:"}))
  end
end
