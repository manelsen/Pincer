defmodule Pincer.Channels.Webhook.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Webhook.RateLimiter

  @ip1 {203, 0, 113, 10}
  @ip2 {203, 0, 113, 11}

  defp start_limiter!(opts) do
    opts = Keyword.merge([name: nil, limit: 2, window_ms: 60_000], opts)
    start_supervised!({RateLimiter, opts})
  end

  test "allows up to the limit and rejects the next request without counting it" do
    limiter = start_limiter!(limit: 2)
    now = 1_000

    assert :ok = RateLimiter.check(limiter, @ip1, now)
    assert :ok = RateLimiter.check(limiter, @ip1, now + 1)

    assert {:error, retry_after} = RateLimiter.check(limiter, @ip1, now + 2)
    assert is_integer(retry_after)
    assert retry_after >= 1
    assert retry_after <= 60

    # A rejected request must not extend or grow the window: the same instant
    # still reports the same reset, and the bucket only refills after the
    # window elapses.
    assert {:error, ^retry_after} = RateLimiter.check(limiter, @ip1, now + 2)

    assert :ok = RateLimiter.check(limiter, @ip1, now + 60_000)
  end

  test "tracks windows per client IP independently" do
    limiter = start_limiter!(limit: 1)
    now = 5_000

    assert :ok = RateLimiter.check(limiter, @ip1, now)
    assert {:error, _retry_after} = RateLimiter.check(limiter, @ip1, now)

    assert :ok = RateLimiter.check(limiter, @ip2, now)
    assert {:error, _retry_after} = RateLimiter.check(limiter, @ip2, now)
  end

  test "resets the fixed window when it elapses" do
    limiter = start_limiter!(limit: 2)

    assert :ok = RateLimiter.check(limiter, @ip1, 0)
    assert :ok = RateLimiter.check(limiter, @ip1, 10)
    assert {:error, _retry_after} = RateLimiter.check(limiter, @ip1, 20)

    assert :ok = RateLimiter.check(limiter, @ip1, 60_000)
    assert :ok = RateLimiter.check(limiter, @ip1, 60_001)
    assert {:error, _retry_after} = RateLimiter.check(limiter, @ip1, 60_002)
  end

  test "returns retry-after in whole seconds, never below one" do
    limiter = start_limiter!(limit: 1)

    assert :ok = RateLimiter.check(limiter, @ip1, 0)
    assert {:error, 60} = RateLimiter.check(limiter, @ip1, 0)
    assert {:error, 60} = RateLimiter.check(limiter, @ip1, 1)
    assert {:error, 50} = RateLimiter.check(limiter, @ip1, 10_000)
    assert {:error, 1} = RateLimiter.check(limiter, @ip1, 59_001)
    assert {:error, 1} = RateLimiter.check(limiter, @ip1, 59_999)
  end

  test "uses the injected clock when no timestamp is supplied" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    limiter =
      start_limiter!(limit: 1, now_fun: fn -> Agent.get(clock, & &1) end)

    assert :ok = RateLimiter.check(limiter, @ip1)
    assert {:error, 60} = RateLimiter.check(limiter, @ip1)

    Agent.update(clock, fn _now -> 60_000 end)

    assert :ok = RateLimiter.check(limiter, @ip1)
  end

  test "prunes stale windows when checking" do
    limiter = start_limiter!(limit: 1)

    assert :ok = RateLimiter.check(limiter, @ip1, 0)
    assert :ok = RateLimiter.check(limiter, @ip2, 60_000)

    assert %{windows: windows} = :sys.get_state(limiter)
    refute Map.has_key?(windows, @ip1)
    assert Map.has_key?(windows, @ip2)
  end
end
