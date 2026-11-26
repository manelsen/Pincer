defmodule Pincer.Adapters.Tools.TimerServerTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.TimerServer
  alias Pincer.Test.Support.SyncHelpers

  setup do
    reg_name = :"timer_reg_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: reg_name})
    srv = start_supervised!({TimerServer, name: nil, registry: reg_name})
    {:ok, %{registry: reg_name, srv: srv}}
  end

  test "delivers {:cron_trigger, prompt} after delay and removes timer", %{
    registry: reg,
    srv: srv
  } do
    {:ok, _} = Registry.register(reg, "sess_1", nil)

    # The delay must be long enough that the pending-state check cannot lose
    # the race against the timer under load, while still keeping the test fast.
    assert {:ok, timer_id} = TimerServer.schedule(srv, "sess_1", "wake up", 300)
    assert is_binary(timer_id)
    assert length(TimerServer.list(srv)) == 1

    assert_receive {:cron_trigger, "wake up"}, 1_000
    SyncHelpers.eventually(fn -> TimerServer.list(srv) == [] end)
    assert TimerServer.list(srv) == []
  end

  test "cancel/2 cancels scheduled timer before it fires", %{registry: reg, srv: srv} do
    {:ok, _} = Registry.register(reg, "sess_2", nil)

    assert {:ok, timer_id} = TimerServer.schedule(srv, "sess_2", "never fire", 300)
    assert :ok = TimerServer.cancel(srv, timer_id)
    assert {:error, :not_found} = TimerServer.cancel(srv, timer_id)

    refute_receive {:cron_trigger, _}, 500
    assert TimerServer.list(srv) == []
  end

  test "handles missing session cleanly without crashing", %{srv: srv} do
    assert {:ok, _} = TimerServer.schedule(srv, "missing_sess", "noop", 15)
    SyncHelpers.eventually(fn -> TimerServer.list(srv) == [] end)
    assert Process.alive?(srv)
    assert TimerServer.list(srv) == []
  end

  test "rejects invalid delays", %{srv: srv} do
    assert {:error, :invalid_delay} = TimerServer.schedule(srv, "s", "x", 0)
    assert {:error, :invalid_delay} = TimerServer.schedule(srv, "s", "x", -10)
    assert {:error, :invalid_delay} = TimerServer.schedule(srv, "s", "x", "10")
  end
end
