defmodule Pincer.Core.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.CircuitBreaker

  setup do
    case GenServer.whereis(CircuitBreaker) do
      nil -> start_supervised!(CircuitBreaker)
      pid when is_pid(pid) -> :ok
    end

    prev_threshold = Application.get_env(:pincer, :circuit_breaker_threshold)
    prev_recovery = Application.get_env(:pincer, :circuit_breaker_recovery_ms)
    prev_probe = Application.get_env(:pincer, :circuit_breaker_probe_ms)

    on_exit(fn ->
      restore_env(:circuit_breaker_threshold, prev_threshold)
      restore_env(:circuit_breaker_recovery_ms, prev_recovery)
      restore_env(:circuit_breaker_probe_ms, prev_probe)
    end)

    name = "test_provider_#{System.unique_integer([:positive])}"
    CircuitBreaker.reset(name)
    {:ok, name: name}
  end

  defp restore_env(key, nil), do: Application.delete_env(:pincer, key)
  defp restore_env(key, val), do: Application.put_env(:pincer, key, val)

  test "starts closed", %{name: name} do
    assert CircuitBreaker.state(name) == :closed
  end

  test "passes through successful calls", %{name: name} do
    result = CircuitBreaker.call(name, fn -> {:ok, "result"} end)
    assert result == {:ok, "result"}
    assert CircuitBreaker.state(name) == :closed
  end

  test "opens after threshold failures", %{name: name} do
    Application.put_env(:pincer, :circuit_breaker_threshold, 3)

    for _ <- 1..3 do
      try do
        CircuitBreaker.call(name, fn -> raise "fail" end)
      rescue
        _ -> :ok
      end
    end

    assert CircuitBreaker.state(name) == :open
    Application.delete_env(:pincer, :circuit_breaker_threshold)
  end

  test "returns circuit_open error when open", %{name: name} do
    Application.put_env(:pincer, :circuit_breaker_threshold, 1)

    try do
      CircuitBreaker.call(name, fn -> raise "fail" end)
    rescue
      _ -> :ok
    end

    assert CircuitBreaker.state(name) == :open

    assert {:error, {:circuit_open, ^name}} = CircuitBreaker.call(name, fn -> :ok end)
    Application.delete_env(:pincer, :circuit_breaker_threshold)
  end

  test "ETS table is protected and owned by CircuitBreaker GenServer" do
    pid = GenServer.whereis(CircuitBreaker)
    assert is_pid(pid)
    assert :ets.info(:pincer_circuit_breaker, :protection) == :protected
    assert :ets.info(:pincer_circuit_breaker, :owner) == pid
  end

  test "serializes concurrent failure counts without lost updates", %{name: name} do
    Application.put_env(:pincer, :circuit_breaker_threshold, 20)

    parent = self()

    tasks =
      for i <- 1..15 do
        Task.async(fn ->
          send(parent, {:ready, i})

          receive do
            :go -> :ok
          end

          try do
            CircuitBreaker.call(name, fn -> raise "fail-#{i}" end)
          rescue
            _ -> :ok
          end
        end)
      end

    for i <- 1..15, do: assert_receive({:ready, ^i})
    for t <- tasks, do: send(t.pid, :go)
    Task.await_many(tasks, 5_000)

    assert CircuitBreaker.state(name) == :closed
    assert {^name, :closed, 15} = Enum.find(CircuitBreaker.summary(), &(elem(&1, 0) == name))
  end

  test "allows only a single probe in half_open state under high concurrency", %{name: name} do
    Application.put_env(:pincer, :circuit_breaker_threshold, 1)
    Application.put_env(:pincer, :circuit_breaker_recovery_ms, 20)

    assert_raise RuntimeError, "trip", fn ->
      CircuitBreaker.call(name, fn -> raise "trip" end)
    end

    assert CircuitBreaker.state(name) == :open
    Process.sleep(30)
    assert CircuitBreaker.state(name) == :half_open

    executions = :atomics.new(1, signed: false)
    parent = self()

    tasks =
      for i <- 1..50 do
        Task.async(fn ->
          send(parent, {:ready, i})

          receive do
            :go -> :ok
          end

          CircuitBreaker.call(name, fn ->
            :atomics.add(executions, 1, 1)
            Process.sleep(40)
            :recovered
          end)
        end)
      end

    for i <- 1..50, do: assert_receive({:ready, ^i})
    for t <- tasks, do: send(t.pid, :go)
    results = Task.await_many(tasks, 5_000)

    assert :atomics.get(executions, 1) == 1
    assert Enum.count(results, &(&1 == :recovered)) == 1
    assert Enum.count(results, &(&1 == {:error, {:circuit_open, name}})) == 49
    assert CircuitBreaker.state(name) == :closed
  end

  test "re-opens and releases half_open probe when probe raises, exits, or throws", %{name: name} do
    Application.put_env(:pincer, :circuit_breaker_threshold, 1)
    Application.put_env(:pincer, :circuit_breaker_recovery_ms, 80)

    assert_raise RuntimeError, "trip", fn ->
      CircuitBreaker.call(name, fn -> raise "trip" end)
    end

    for action <- [
          fn -> raise "probe boom" end,
          fn -> exit(:probe_exit) end,
          fn -> throw(:probe_throw) end
        ] do
      Process.sleep(95)
      assert CircuitBreaker.state(name) == :half_open

      caught =
        try do
          CircuitBreaker.call(name, action)
        catch
          kind, reason -> {kind, reason}
        end

      assert elem(caught, 0) in [:error, :exit, :throw]
      assert CircuitBreaker.state(name) == :open
      assert {:error, {:circuit_open, ^name}} = CircuitBreaker.call(name, fn -> :ok end)
    end

    Process.sleep(95)
    assert :ok = CircuitBreaker.call(name, fn -> :ok end)
    assert CircuitBreaker.state(name) == :closed
  end

  test "releases half_open probe and re-opens if probe process is killed", %{name: name} do
    Application.put_env(:pincer, :circuit_breaker_threshold, 1)
    Application.put_env(:pincer, :circuit_breaker_recovery_ms, 80)

    assert_raise RuntimeError, "trip", fn ->
      CircuitBreaker.call(name, fn -> raise "trip" end)
    end

    Process.sleep(95)
    assert CircuitBreaker.state(name) == :half_open

    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        CircuitBreaker.call(name, fn ->
          send(parent, :probe_started)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :probe_started
    assert {:error, {:circuit_open, ^name}} = CircuitBreaker.call(name, fn -> :ok end)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # Cross-process monitor delivery order is not guaranteed; wait for CircuitBreaker to handle {:DOWN, ...}.
    wait_until(fn -> CircuitBreaker.state(name) == :open end)

    Process.sleep(95)
    assert :recovered = CircuitBreaker.call(name, fn -> :recovered end)
    assert CircuitBreaker.state(name) == :closed
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(2)
      wait_until(fun, attempts - 1)
    end
  end

  test "allows nested and recursive calls without deadlocking", %{name: name} do
    other = "#{name}_other"
    on_exit(fn -> CircuitBreaker.reset(other) end)

    assert :nested_ok =
             CircuitBreaker.call(name, fn ->
               CircuitBreaker.call(other, fn -> :nested_ok end)
             end)

    Application.put_env(:pincer, :circuit_breaker_threshold, 1)
    Application.put_env(:pincer, :circuit_breaker_recovery_ms, 15)

    assert_raise RuntimeError, "trip", fn ->
      CircuitBreaker.call(name, fn -> raise "trip" end)
    end

    Process.sleep(25)

    assert {:outer_ok, {:error, {:circuit_open, ^name}}} =
             CircuitBreaker.call(name, fn ->
               inner = CircuitBreaker.call(name, fn -> :should_not_run end)
               {:outer_ok, inner}
             end)

    assert CircuitBreaker.state(name) == :closed
  end

  test "replaces timed-out half_open probe and ignores stale probe completion", %{name: name} do
    Application.put_env(:pincer, :circuit_breaker_threshold, 1)
    Application.put_env(:pincer, :circuit_breaker_recovery_ms, 15)
    Application.put_env(:pincer, :circuit_breaker_probe_ms, 25)

    assert_raise RuntimeError, "trip", fn ->
      CircuitBreaker.call(name, fn -> raise "trip" end)
    end

    Process.sleep(25)
    assert CircuitBreaker.state(name) == :half_open

    parent = self()

    slow_probe =
      Task.async(fn ->
        try do
          CircuitBreaker.call(name, fn ->
            send(parent, :slow_probe_started)

            receive do
              :finish_and_fail -> raise "late stale failure"
            end
          end)
        rescue
          RuntimeError -> :stale_failed
        end
      end)

    assert_receive :slow_probe_started
    assert {:error, {:circuit_open, ^name}} = CircuitBreaker.call(name, fn -> :too_early end)

    Process.sleep(35)
    assert :fresh_ok = CircuitBreaker.call(name, fn -> :fresh_ok end)
    assert CircuitBreaker.state(name) == :closed

    send(slow_probe.pid, :finish_and_fail)
    assert :stale_failed == Task.await(slow_probe, 5_000)
    assert CircuitBreaker.state(name) == :closed
  end
end
