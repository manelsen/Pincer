defmodule Pincer.Core.CircuitBreakerTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Pincer.Core.CircuitBreaker
  alias Pincer.Infra.CircuitBreakerSnapshot
  alias Pincer.Infra.Repo

  setup do
    Application.ensure_all_started(:pincer)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    case GenServer.whereis(CircuitBreaker) do
      nil -> start_supervised!(CircuitBreaker)
      _ -> :ok
    end

    name = "test_provider_#{System.unique_integer()}"
    CircuitBreaker.reset(name)
    Repo.delete_all(from(s in CircuitBreakerSnapshot, where: s.name == ^name))
    {:ok, name: name}
  end

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
        CircuitBreaker.call(name, fn -> raise "boom" end)
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
      CircuitBreaker.call(name, fn -> raise "boom" end)
    rescue
      _ -> :ok
    end

    assert {:error, {:circuit_open, ^name}} = CircuitBreaker.call(name, fn -> :ok end)
    Application.delete_env(:pincer, :circuit_breaker_threshold)
  end

  test "persists open state to Postgres when threshold is reached", %{name: name} do
    Application.put_env(:pincer, :circuit_breaker_threshold, 2)

    for _ <- 1..2 do
      try do
        CircuitBreaker.call(name, fn -> raise "persist_test" end)
      rescue
        _ -> :ok
      end
    end

    assert CircuitBreaker.state(name) == :open

    Process.sleep(50)
    snap = Repo.get(CircuitBreakerSnapshot, name)
    assert snap != nil
    assert snap.state == "open"
    assert snap.failure_count == 2

    Application.delete_env(:pincer, :circuit_breaker_threshold)
  end

  test "removes snapshot from Postgres when circuit closes after success", %{name: name} do
    Application.put_env(:pincer, :circuit_breaker_threshold, 1)

    try do
      CircuitBreaker.call(name, fn -> raise "close_test" end)
    rescue
      _ -> :ok
    end

    assert CircuitBreaker.state(name) == :open
    Process.sleep(50)
    assert Repo.get(CircuitBreakerSnapshot, name) != nil

    # Recovery: force half_open and then succeed
    Application.put_env(:pincer, :circuit_breaker_recovery_ms, 0)
    assert CircuitBreaker.state(name) == :half_open
    CircuitBreaker.call(name, fn -> :ok end)
    assert CircuitBreaker.state(name) == :closed
    Process.sleep(50)
    assert Repo.get(CircuitBreakerSnapshot, name) == nil

    Application.delete_env(:pincer, :circuit_breaker_threshold)
    Application.delete_env(:pincer, :circuit_breaker_recovery_ms)
  end
end
