defmodule Pincer.Core.Orchestration.SubAgentRegistryTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Orchestration.SubAgentRegistry

  setup do
    Application.ensure_all_started(:pincer)

    prev_global = Application.get_env(:pincer, :max_subagents)
    prev_session = Application.get_env(:pincer, :max_subagents_per_session)
    {:ok, reserved} = Agent.start(fn -> [] end)

    on_exit(fn ->
      ids = Agent.get(reserved, & &1)
      Enum.each(ids, &SubAgentRegistry.release/1)
      Agent.stop(reserved)
      restore_env(:max_subagents, prev_global)
      restore_env(:max_subagents_per_session, prev_session)
    end)

    {:ok, reserved: reserved}
  end

  test "reserve enforces the global cap and treats :infinity as uncapped", %{reserved: reserved} do
    Application.put_env(:pincer, :max_subagents_per_session, :infinity)
    Application.put_env(:pincer, :max_subagents, SubAgentRegistry.count() + 2)

    id1 = reserve!(reserved, "global-1", unique_session())
    id2 = reserve!(reserved, "global-2", unique_session())

    assert {:error, :global_limit} =
             SubAgentRegistry.reserve(unique_id("global-3"), unique_session())

    SubAgentRegistry.release(id1)
    SubAgentRegistry.release(id2)

    Application.put_env(:pincer, :max_subagents, :infinity)
    id4 = reserve!(reserved, "global-4", unique_session())
    id5 = reserve!(reserved, "global-5", unique_session())
    assert is_binary(id4) and is_binary(id5)
  end

  test "reserve enforces the per-session cap independently of the global cap", %{
    reserved: reserved
  } do
    Application.put_env(:pincer, :max_subagents, :infinity)
    Application.put_env(:pincer, :max_subagents_per_session, 1)

    session = unique_session()
    other_session = unique_session()

    id = reserve!(reserved, "session-1", session)

    assert {:error, :session_limit} = SubAgentRegistry.reserve(unique_id("session-2"), session)

    other_id = unique_id("session-other")
    assert :ok = SubAgentRegistry.reserve(other_id, other_session)
    Agent.update(reserved, &[other_id | &1])

    SubAgentRegistry.release(id)
    assert SubAgentRegistry.count_for(session) == 0
    assert SubAgentRegistry.count_for(other_session) == 1
  end

  test "track monitors the pid and removes the entry on :DOWN", %{reserved: reserved} do
    Application.put_env(:pincer, :max_subagents, :infinity)
    Application.put_env(:pincer, :max_subagents_per_session, :infinity)

    session = unique_session()
    id = reserve!(reserved, "tracked", session)

    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(pid)

    assert :ok = SubAgentRegistry.track(id, pid)
    assert SubAgentRegistry.lookup(id) == {:ok, pid}
    assert SubAgentRegistry.count_for(session) == 1

    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    wait_until(fn -> SubAgentRegistry.lookup(id) == :error end)
    assert SubAgentRegistry.count_for(session) == 0

    assert :ok = SubAgentRegistry.release(id)
    assert :ok = SubAgentRegistry.release(id)
  end

  test "counts reflect reserved ids and release clears them", %{reserved: reserved} do
    Application.put_env(:pincer, :max_subagents, :infinity)
    Application.put_env(:pincer, :max_subagents_per_session, :infinity)

    session = unique_session()
    baseline = SubAgentRegistry.count()

    id = reserve!(reserved, "counts", session)

    assert SubAgentRegistry.count_for(session) == 1
    assert SubAgentRegistry.count() >= baseline + 1

    SubAgentRegistry.release(id)

    assert SubAgentRegistry.lookup(id) == :error
    assert SubAgentRegistry.count_for(session) == 0
  end

  defp reserve!(reserved, prefix, session) do
    id = unique_id(prefix)
    assert :ok = SubAgentRegistry.reserve(id, session)
    Agent.update(reserved, &[id | &1])
    id
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp unique_session, do: "registry-#{System.unique_integer([:positive])}"

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(5)
        wait_until(fun, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:pincer, key)
  defp restore_env(key, value), do: Application.put_env(:pincer, key, value)
end
