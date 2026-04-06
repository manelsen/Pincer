defmodule Pincer.Chaos.MultiChannelStressTest do
  @moduledoc """
  Stress tests simulating concurrent activity across multiple channels.
  Validates that channel supervisors handle load without crashing.
  """
  use ExUnit.Case, async: false

  @tag :stress
  @tag timeout: 60_000
  test "1000 concurrent mock LLM requests complete without crash" do
    messages = [%{"role" => "user", "content" => "stress test"}]

    tasks =
      for _i <- 1..1000 do
        Task.async(fn ->
          Pincer.LLM.Client.chat_completion(messages, provider: "mock")
        end)
      end

    results = Task.await_many(tasks, 30_000)

    errors =
      Enum.reject(results, fn
        {:ok, _, _} -> true
        {:ok, _} -> true
        _ -> false
      end)

    # At most 1% failure rate under stress
    assert length(errors) / 1000 < 0.01,
           "Error rate too high: #{length(errors)}/1000 failures"
  end

  @tag :stress
  test "process mailbox does not overflow under concurrent requests" do
    initial_memory = :erlang.memory(:processes)

    tasks =
      for _ <- 1..100 do
        Task.async(fn ->
          Pincer.LLM.Client.chat_completion(
            [%{"role" => "user", "content" => "memory test"}],
            provider: "mock"
          )
        end)
      end

    Task.await_many(tasks, 15_000)

    final_memory = :erlang.memory(:processes)
    growth_mb = (final_memory - initial_memory) / (1024 * 1024)

    # Memory growth should be under 50MB for 100 concurrent requests
    assert growth_mb < 50,
           "Excessive memory growth: #{Float.round(growth_mb, 2)}MB for 100 requests"
  end
end
