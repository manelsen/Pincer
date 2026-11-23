defmodule Pincer.Core.Orchestration.SubAgentRegistryTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Orchestration.SubAgentRegistry

  setup do
    Application.ensure_all_started(:pincer)

    prev_global = Application.get_env(:pincer, :max_subagents)
    prev_session = Application.get_env(:pincer, :max_subagents_per_session)
    prev_tree_tokens = Application.get_env(:pincer, :max_subagent_tree_tokens)
    prev_tree_ms = Application.get_env(:pincer, :max_subagent_tree_ms)
    original_now_fun = registry_now_fun()
    {:ok, reserved} = Agent.start(fn -> [] end)

    on_exit(fn ->
      ids = Agent.get(reserved, & &1)
      Enum.each(ids, &SubAgentRegistry.release/1)
      Agent.stop(reserved)
      restore_env(:max_subagents, prev_global)
      restore_env(:max_subagents_per_session, prev_session)
      restore_env(:max_subagent_tree_tokens, prev_tree_tokens)
      restore_env(:max_subagent_tree_ms, prev_tree_ms)
      restore_now_fun(original_now_fun)
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
    assert id4 != id5
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
    assert SubAgentRegistry.tree_usage(session) == :error

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

  test "tree token cap rejects at or over budget and accepts below", %{reserved: reserved} do
    Application.put_env(:pincer, :max_subagents, :infinity)
    Application.put_env(:pincer, :max_subagents_per_session, :infinity)
    Application.put_env(:pincer, :max_subagent_tree_tokens, 10)

    root = unique_session()
    id1 = reserve!(reserved, "tree-token-1", root)

    assert {:ok, %{tokens: 0}} = SubAgentRegistry.tree_usage(root)

    assert :ok = SubAgentRegistry.add_usage(root, 9)
    id2 = reserve!(reserved, "tree-token-2", root)

    assert :ok = SubAgentRegistry.add_usage(root, 1)
    assert {:ok, %{tokens: 10}} = SubAgentRegistry.tree_usage(root)

    count = SubAgentRegistry.count()

    assert {:error, :tree_token_budget} =
             SubAgentRegistry.reserve(unique_id("tree-token-over"), root)

    assert SubAgentRegistry.count() == count

    SubAgentRegistry.release(id1)
    SubAgentRegistry.release(id2)
    assert SubAgentRegistry.tree_usage(root) == :error

    id3 = reserve!(reserved, "tree-token-3", root)
    assert {:ok, %{tokens: 0}} = SubAgentRegistry.tree_usage(root)
    SubAgentRegistry.release(id3)
  end

  test "tree deadline rejects once the injected clock reaches the cap", %{reserved: reserved} do
    Application.put_env(:pincer, :max_subagents, :infinity)
    Application.put_env(:pincer, :max_subagents_per_session, :infinity)
    Application.put_env(:pincer, :max_subagent_tree_tokens, :infinity)
    Application.put_env(:pincer, :max_subagent_tree_ms, 1_000)

    clock = start_supervised!({Agent, fn -> 0 end})
    inject_clock!(fn -> Agent.get(clock, & &1) end)

    root = unique_session()
    id1 = reserve!(reserved, "tree-deadline-1", root)

    Agent.update(clock, fn _ -> 999 end)
    id2 = reserve!(reserved, "tree-deadline-2", root)
    assert {:ok, %{age_ms: 999}} = SubAgentRegistry.tree_usage(root)

    Agent.update(clock, fn _ -> 1_000 end)
    count = SubAgentRegistry.count()

    assert {:error, :tree_deadline} = SubAgentRegistry.reserve(unique_id("tree-deadline-3"), root)
    assert SubAgentRegistry.count() == count

    SubAgentRegistry.release(id1)
    SubAgentRegistry.release(id2)
    assert SubAgentRegistry.tree_usage(root) == :error
  end

  test "tree caps of 0 and :infinity disable enforcement", %{reserved: reserved} do
    Application.put_env(:pincer, :max_subagents, :infinity)
    Application.put_env(:pincer, :max_subagents_per_session, :infinity)

    clock = start_supervised!({Agent, fn -> 0 end})
    inject_clock!(fn -> Agent.get(clock, & &1) end)

    Application.put_env(:pincer, :max_subagent_tree_tokens, 0)
    Application.put_env(:pincer, :max_subagent_tree_ms, 0)

    zero_root = unique_session()
    zero_id1 = reserve!(reserved, "tree-zero-1", zero_root)
    assert :ok = SubAgentRegistry.add_usage(zero_root, 1_000_000)
    Agent.update(clock, fn _ -> 10_000_000 end)
    zero_id2 = reserve!(reserved, "tree-zero-2", zero_root)

    SubAgentRegistry.release(zero_id1)
    SubAgentRegistry.release(zero_id2)

    Application.put_env(:pincer, :max_subagent_tree_tokens, :infinity)
    Application.put_env(:pincer, :max_subagent_tree_ms, :infinity)

    infinity_root = unique_session()
    infinity_id1 = reserve!(reserved, "tree-infinity-1", infinity_root)
    assert :ok = SubAgentRegistry.add_usage(infinity_root, 1_000_000_000)
    Agent.update(clock, fn _ -> 20_000_000 end)
    infinity_id2 = reserve!(reserved, "tree-infinity-2", infinity_root)

    SubAgentRegistry.release(infinity_id1)
    SubAgentRegistry.release(infinity_id2)
  end

  test "usage accumulates across reservations and resets after the last release", %{
    reserved: reserved
  } do
    Application.put_env(:pincer, :max_subagents, :infinity)
    Application.put_env(:pincer, :max_subagents_per_session, :infinity)
    Application.put_env(:pincer, :max_subagent_tree_tokens, :infinity)

    root = unique_session()
    id1 = reserve!(reserved, "tree-usage-1", root)

    assert :ok = SubAgentRegistry.add_usage(root, 3)
    assert :ok = SubAgentRegistry.add_usage(root, 4)
    assert {:ok, %{tokens: 7}} = SubAgentRegistry.tree_usage(root)

    id2 = reserve!(reserved, "tree-usage-2", root)
    assert {:ok, %{tokens: 7}} = SubAgentRegistry.tree_usage(root)

    SubAgentRegistry.release(id1)
    assert {:ok, %{tokens: 7}} = SubAgentRegistry.tree_usage(root)

    SubAgentRegistry.release(id2)
    assert SubAgentRegistry.tree_usage(root) == :error

    id3 = reserve!(reserved, "tree-usage-3", root)
    assert {:ok, %{tokens: 0}} = SubAgentRegistry.tree_usage(root)
    SubAgentRegistry.release(id3)
  end

  test "add_usage ignores invalid tokens and unknown or removed trees", %{reserved: reserved} do
    Application.put_env(:pincer, :max_subagents, :infinity)
    Application.put_env(:pincer, :max_subagents_per_session, :infinity)

    unknown = unique_session("tree-unknown")
    assert :ok = SubAgentRegistry.add_usage(unknown, 5)
    assert SubAgentRegistry.tree_usage(unknown) == :error

    root = unique_session()
    id = reserve!(reserved, "tree-invalid-usage", root)

    assert :ok = SubAgentRegistry.add_usage(root, -1)
    assert :ok = SubAgentRegistry.add_usage(root, "5")
    assert :ok = SubAgentRegistry.add_usage(root, 1.5)
    assert {:ok, %{tokens: 0}} = SubAgentRegistry.tree_usage(root)

    assert :ok = SubAgentRegistry.add_usage(root, 4)
    assert {:ok, %{tokens: 4}} = SubAgentRegistry.tree_usage(root)

    SubAgentRegistry.release(id)
    assert :ok = SubAgentRegistry.add_usage(root, 5)
    assert SubAgentRegistry.tree_usage(root) == :error
  end

  test "tree_usage reports tokens and age from the injected clock", %{reserved: reserved} do
    Application.put_env(:pincer, :max_subagents, :infinity)
    Application.put_env(:pincer, :max_subagents_per_session, :infinity)

    clock = start_supervised!({Agent, fn -> 100 end})
    inject_clock!(fn -> Agent.get(clock, & &1) end)

    root = unique_session()
    id = reserve!(reserved, "tree-report", root)

    assert {:ok, %{tokens: 0, age_ms: 0}} = SubAgentRegistry.tree_usage(root)

    Agent.update(clock, fn _ -> 350 end)
    assert :ok = SubAgentRegistry.add_usage(root, 5)
    assert {:ok, %{tokens: 5, age_ms: 250}} = SubAgentRegistry.tree_usage(root)

    SubAgentRegistry.release(id)
  end

  defp reserve!(reserved, prefix, session) do
    id = unique_id(prefix)
    assert :ok = SubAgentRegistry.reserve(id, session)
    Agent.update(reserved, &[id | &1])
    id
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp unique_session(prefix \\ "registry"), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp inject_clock!(fun) do
    :sys.replace_state(SubAgentRegistry, &Map.put(&1, :now_fun, fun))
  end

  defp registry_now_fun do
    SubAgentRegistry
    |> :sys.get_state()
    |> Map.get(:now_fun, fn -> System.monotonic_time(:millisecond) end)
  end

  defp restore_now_fun(fun) do
    if Process.whereis(SubAgentRegistry) do
      :sys.replace_state(SubAgentRegistry, &Map.put(&1, :now_fun, fun))
    end

    :ok
  end

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
