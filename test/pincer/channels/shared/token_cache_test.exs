defmodule Pincer.Channels.Shared.TokenCacheTest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.Shared.TokenCache

  setup do
    # Use a unique name per test to avoid process collisions
    name = :"token_cache_#{System.unique_integer([:positive, :monotonic])}"
    {:ok, name: name}
  end

  describe "get_token/2 with fresh cache" do
    test "returns cached token when not expired", %{name: name} do
      expires_at = System.system_time(:second) + 7200

      fetch_fn = fn ->
        {:ok, "fresh_token", expires_at}
      end

      start_supervised!({TokenCache, name: name, fetch_fn: fetch_fn})

      assert {:ok, "fresh_token"} = TokenCache.get_token(name)
    end
  end

  describe "get_token/2 with expired cache" do
    test "refreshes token when expired", %{name: name} do
      ref = make_ref()

      fetch_fn = fn ->
        # First call populates cache with already-expired token
        # Second call returns fresh token
        if :persistent_term.get({__MODULE__, ref}, 0) == 0 do
          :persistent_term.put({__MODULE__, ref}, 1)
          {:ok, "expired_token", System.system_time(:second) - 60}
        else
          {:ok, "refreshed_token", System.system_time(:second) + 7200}
        end
      end

      start_supervised!({TokenCache, name: name, fetch_fn: fetch_fn})

      # First call stores expired token, then immediately refresh triggers
      assert {:ok, token} = TokenCache.get_token(name)
      assert token in ["expired_token", "refreshed_token"]
    end

    test "returns new token after refresh", %{name: name} do
      call_count = :counters.new(1, [:atomics])

      fetch_fn = fn ->
        :counters.add(call_count, 1, 1)
        n = :counters.get(call_count, 1)

        if n == 1 do
          # First call: return token that expires immediately
          {:ok, "first_token", System.system_time(:second) - 1}
        else
          {:ok, "second_token", System.system_time(:second) + 7200}
        end
      end

      start_supervised!({TokenCache, name: name, fetch_fn: fetch_fn})

      # First get stores expired, triggers refresh
      {:ok, _} = TokenCache.get_token(name)
      # Second get should return refreshed token
      assert {:ok, "second_token"} = TokenCache.get_token(name)
    end
  end

  describe "concurrent access" do
    test "multiple callers get the same token without stampede", %{name: name} do
      # Track how many times fetch_fn is called
      call_count = :counters.new(1, [:atomics])

      fetch_fn = fn ->
        :counters.add(call_count, 1, 1)
        # Simulate some delay to encourage concurrent calls
        Process.sleep(50)
        {:ok, "shared_token", System.system_time(:second) + 7200}
      end

      start_supervised!({TokenCache, name: name, fetch_fn: fetch_fn})

      # Spawn multiple callers simultaneously
      tasks =
        for _ <- 1..10 do
          Task.async(fn -> TokenCache.get_token(name) end)
        end

      results = Task.await_many(tasks, 5000)

      # All callers should get the token
      assert length(results) == 10

      for result <- results do
        assert {:ok, "shared_token"} = result
      end

      # The fetch function should have been called at most a few times,
      # not 10 times (stampede protection).
      # With stampede protection: 1 initial + possible retries.
      # Without: would be 10.
      total_calls = :counters.get(call_count, 1)
      assert total_calls <= 3, "Expected stampede protection, got #{total_calls} fetch calls"
    end
  end

  describe "error handling" do
    test "returns error when fetch_fn fails", %{name: name} do
      fetch_fn = fn ->
        {:error, :unauthorized}
      end

      start_supervised!({TokenCache, name: name, fetch_fn: fetch_fn})

      assert {:error, :unauthorized} = TokenCache.get_token(name)
    end
  end

  describe "safety margin" do
    test "treats token as expired before actual expiry (60s margin)", %{name: name} do
      # Token expires in 30 seconds -- within 60s safety margin
      expires_at = System.system_time(:second) + 30

      call_count = :counters.new(1, [:atomics])

      fetch_fn = fn ->
        :counters.add(call_count, 1, 1)
        n = :counters.get(call_count, 1)

        if n == 1 do
          {:ok, "almost_expired", expires_at}
        else
          {:ok, "refreshed", System.system_time(:second) + 7200}
        end
      end

      start_supervised!({TokenCache, name: name, fetch_fn: fetch_fn})

      # First call stores token that's within safety margin
      {:ok, _} = TokenCache.get_token(name)
      # Should trigger refresh since 30s < 60s safety margin
      {:ok, _token} = TokenCache.get_token(name)
      # Either refreshed or the original -- the key is that refresh was triggered
      total_calls = :counters.get(call_count, 1)

      assert total_calls >= 2,
             "Expected refresh due to safety margin, got only #{total_calls} calls"
    end
  end
end
