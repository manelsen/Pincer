# Run with: mix run test/bench/llm_client_bench.exs
# Requires mock provider configured

defmodule Pincer.Bench.LLMClient do
  @moduledoc "Benchmark suite for LLM client dispatch and retry logic."

  alias Pincer.LLM.Client

  def messages do
    [
      %{"role" => "user", "content" => "Hello, benchmark test."}
    ]
  end

  def run do
    Benchee.run(
      %{
        "mock_provider_dispatch" => fn ->
          Client.chat_completion(messages(), provider: "mock")
        end
      },
      time: 10,
      warmup: 2,
      memory_time: 2,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.JSON, file: "test/bench/results/llm_bench.json"}
      ]
    )
  end
end

Pincer.Bench.LLMClient.run()
