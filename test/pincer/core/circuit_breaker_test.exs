defmodule Pincer.Core.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.CircuitBreaker

  setup do
    case GenServer.whereis(CircuitBreaker) do
      nil -> start_supervised!(CircuitBreaker)
      _ -> :ok
    end

    name = "test_provider_#{System.unique_integer()}"
    CircuitBreaker.reset(name)
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
end
