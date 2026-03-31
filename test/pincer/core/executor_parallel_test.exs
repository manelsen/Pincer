defmodule Pincer.Core.ExecutorParallelTest do
  use ExUnit.Case, async: false
  import Mox

  # Define mocks for the ports
  Mox.defmock(Pincer.MockToolRegistryParallel, for: Pincer.Ports.ToolRegistry)
  Mox.defmock(Pincer.MockLLMClientParallel, for: Pincer.Ports.LLM)

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "executes multiple tool calls in parallel" do
    session_pid = self()
    session_id = "parallel_test_session"
    history = [%{"role" => "user", "content" => "Run two tools"}]

    Pincer.MockToolRegistryParallel
    |> stub(:list_tools, fn -> [] end)
    |> expect(:execute_tool, fn name, _args, _ctx ->
      Process.sleep(500)
      {:ok, "Result from #{name}"}
    end)
    |> expect(:execute_tool, fn name, _args, _ctx ->
      Process.sleep(500)
      {:ok, "Result from #{name}"}
    end)

    Pincer.MockLLMClientParallel
    |> expect(:stream_completion, fn _history, _opts ->
      chunk = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_1",
                  "function" => %{"name" => "tool_a", "arguments" => "{}"}
                },
                %{
                  "index" => 1,
                  "id" => "call_2",
                  "function" => %{"name" => "tool_b", "arguments" => "{}"}
                }
              ]
            }
          }
        ]
      }
      {:ok, [chunk]}
    end)
    |> expect(:stream_completion, fn history, _opts ->
      # Verify both tool results are in history
      tool_results = Enum.filter(history, &(&1["role"] == "tool"))
      assert length(tool_results) == 2
      
      names = Enum.map(tool_results, &(&1["name"])) |> Enum.sort()
      assert names == ["tool_a", "tool_b"]

      {:ok, [%{"choices" => [%{"delta" => %{"content" => "Done"}}]}]}
    end)

    start_time = System.monotonic_time(:millisecond)

    {:ok, _pid} =
      Pincer.Core.Executor.start(session_pid, session_id, history,
        tool_registry: Pincer.MockToolRegistryParallel,
        llm_client: Pincer.MockLLMClientParallel
      )

    assert_receive {:executor_finished, _, "Done", _usage}, 5000

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    # If sequential, it should take ~1000ms. If parallel, ~500ms + overhead.
    assert duration < 850, "Expected parallel execution to take less than 850ms, but took #{duration}ms"
  end
end
