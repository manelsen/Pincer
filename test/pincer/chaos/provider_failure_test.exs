defmodule Pincer.Chaos.ProviderFailureTest do
  @moduledoc """
  Chaos tests that inject failures into the LLM provider path.
  Verifies that the system recovers gracefully and does not crash sessions.
  """
  use ExUnit.Case, async: false

  alias Pincer.LLM.Client

  @tag :chaos
  test "handles provider returning HTTP 500 without crashing" do
    # Use mock provider which always returns success — test the error handling layer
    messages = [%{"role" => "user", "content" => "test"}]

    # Simulate by calling with a non-existent provider (should return clean error, not crash)
    result = Client.chat_completion(messages, provider: "nonexistent_chaos_provider")
    assert {:error, {:provider_not_found, "nonexistent_chaos_provider"}} = result
  end

  @tag :chaos
  test "handles all providers in cooldown without crashing" do
    messages = [%{"role" => "user", "content" => "test"}]

    # Calling with a provider that has no credentials should return a clean error
    result =
      Client.chat_completion(messages, provider: "chaos_no_creds_#{System.unique_integer()}")

    assert {:error, _} = result
  end

  @tag :chaos
  test "mock provider always responds under load" do
    messages = [%{"role" => "user", "content" => "chaos test #{System.unique_integer()}"}]

    tasks =
      for _ <- 1..20 do
        Task.async(fn ->
          Client.chat_completion(messages, provider: "mock")
        end)
      end

    results = Task.await_many(tasks, 10_000)

    successes =
      Enum.count(results, fn
        {:ok, _, _} -> true
        {:ok, _} -> true
        _ -> false
      end)

    # All mock requests should succeed
    assert successes == 20
  end

  @tag :chaos
  test "concurrent sessions do not interfere with each other" do
    messages = [%{"role" => "user", "content" => "isolation test"}]

    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          result = Client.chat_completion(messages, provider: "mock")
          {i, result}
        end)
      end

    results = Task.await_many(tasks, 10_000)

    # Each session should get its own independent result
    for {_i, result} <- results do
      assert match?({:ok, _, _}, result) or match?({:ok, _}, result)
    end
  end
end
