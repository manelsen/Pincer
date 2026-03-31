defmodule Pincer.Core.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.RateLimiter

  setup do
    # Start the rate limiter if not already running
    case GenServer.whereis(RateLimiter) do
      nil -> start_supervised!(RateLimiter)
      _ -> :ok
    end

    :ok
  end

  test "allows requests within limit" do
    key = "test_user_#{System.unique_integer()}"
    assert :ok = RateLimiter.check(:cli, key)
    assert :ok = RateLimiter.check(:cli, key)
  end

  test "blocks requests exceeding limit for a channel" do
    key = "test_burst_#{System.unique_integer()}"
    # whatsapp limit is 10/60s
    for _ <- 1..10, do: RateLimiter.check(:whatsapp, key)
    assert {:error, :rate_limited, _retry_ms} = RateLimiter.check(:whatsapp, key)
  end

  test "different keys are independent" do
    key1 = "key_a_#{System.unique_integer()}"
    key2 = "key_b_#{System.unique_integer()}"
    for _ <- 1..10, do: RateLimiter.check(:whatsapp, key1)
    assert :ok = RateLimiter.check(:whatsapp, key2)
  end
end
