defmodule Pincer.Core.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.RateLimiter

  setup do
    # Start the rate limiter if not already running
    case GenServer.whereis(RateLimiter) do
      nil -> start_supervised!(RateLimiter)
      _ -> :ok
    end

    prev_limits = Application.get_env(:pincer, :rate_limits)

    on_exit(fn ->
      if is_nil(prev_limits) do
        Application.delete_env(:pincer, :rate_limits)
      else
        Application.put_env(:pincer, :rate_limits, prev_limits)
      end
    end)

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

  test "ETS table is protected and owned by RateLimiter GenServer" do
    pid = GenServer.whereis(RateLimiter)
    assert is_pid(pid)
    assert :ets.info(:pincer_rate_limiter, :protection) == :protected
    assert :ets.info(:pincer_rate_limiter, :owner) == pid
  end

  test "enforces exact window limit under high concurrency without TOCTOU overshoot" do
    key = "concurrent_#{System.unique_integer([:positive])}"
    parent = self()

    # whatsapp limit is 10 / 60s; 50 concurrent callers should yield exactly 10 :ok
    tasks =
      for i <- 1..50 do
        Task.async(fn ->
          send(parent, {:ready, i})

          receive do
            :go -> :ok
          end

          RateLimiter.check(:whatsapp, key)
        end)
      end

    for i <- 1..50, do: assert_receive({:ready, ^i})
    for t <- tasks, do: send(t.pid, :go)
    results = Task.await_many(tasks, 5_000)

    assert Enum.count(results, &(&1 == :ok)) == 10
    assert Enum.count(results, &match?({:error, :rate_limited, _}, &1)) == 40
  end

  test "allows requests after window expiration and supports reset/2" do
    Application.put_env(:pincer, :rate_limits, %{short_win: {2, 40}})
    key = "window_#{System.unique_integer([:positive])}"

    assert :ok = RateLimiter.check(:short_win, key)
    assert :ok = RateLimiter.check(:short_win, key)
    assert {:error, :rate_limited, retry_ms} = RateLimiter.check(:short_win, key)
    assert retry_ms > 0

    Process.sleep(50)
    assert :ok = RateLimiter.check(:short_win, key)
    assert :ok = RateLimiter.check(:short_win, key)
    assert {:error, :rate_limited, _} = RateLimiter.check(:short_win, key)

    assert :ok = RateLimiter.reset(:short_win, key)
    assert :ok = RateLimiter.check(:short_win, key)
  end

  test "handles zero limit, string channel names, and reset/0" do
    Application.put_env(:pincer, :rate_limits, %{zero_chan: {0, 1_000}})
    key = "zero_#{System.unique_integer([:positive])}"

    assert {:error, :rate_limited, 1_000} = RateLimiter.check(:zero_chan, key)
    assert :ok = RateLimiter.check("cli", key)
    assert :ok = RateLimiter.reset()
  end
end
