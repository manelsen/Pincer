defmodule Pincer.Core.ExecutorHexTest do
  use ExUnit.Case, async: true
  import Mox

  # Define mocks for the ports
  Mox.defmock(Pincer.MockToolRegistry, for: Pincer.Core.Ports.ToolRegistry)
  Mox.defmock(Pincer.MockLLMClient, for: Pincer.Core.Ports.LLM)

  setup :verify_on_exit!

  describe "Executor with injected dependencies" do
    test "uses injected tool registry and llm client" do
      session_pid = self()
      session_id = "hex_test_session"
      history = [%{"role" => "user", "content" => "Hello"}]

      # 1. Setup Tool Registry Mock
      Pincer.MockToolRegistry
      |> expect(:list_tools, fn -> 
        [%{"name" => "mock_tool", "description" => "A mock tool"}]
      end)

      # 2. Setup LLM Client Mock
      Pincer.MockLLMClient
      |> expect(:stream_completion, fn _history, opts ->
        # Verify tools were passed to LLM
        tools = Keyword.get(opts, :tools)
        assert length(tools) == 1
        assert List.first(tools)["name"] == "mock_tool"
        
        # Return a simple stream response
        {:ok, [%{"choices" => [%{"delta" => %{"content" => "Hello from Mock LLM"}}]}]}
      end)

      # 3. Start Executor with injected deps
      {:ok, _pid} = Pincer.Core.Executor.start(session_pid, session_id, history, 
        tool_registry: Pincer.MockToolRegistry,
        llm_client: Pincer.MockLLMClient
      )

      # 4. Assert we receive the finished message
      assert_receive {:executor_finished, _new_history, "Hello from Mock LLM"}, 1000
    end

    test "executes tools via registry" do
      session_pid = self()
      session_id = "tool_exec_session"
      history = [%{"role" => "user", "content" => "Run tool"}]

      Pincer.MockToolRegistry
      |> stub(:list_tools, fn -> [] end)
      |> expect(:execute_tool, fn "my_tool", %{"arg" => "val"}, _ctx ->
        {:ok, "Tool Result"}
      end)

      Pincer.MockLLMClient
      |> expect(:stream_completion, fn _history, _opts ->
        # Simulate LLM returning a tool call
        chunk1 = %{"choices" => [%{"delta" => %{"tool_calls" => [%{"index" => 0, "id" => "call_1", "function" => %{"name" => "my_tool", "arguments" => "{\"arg\": \"val\"}"}}]}}]}
        # Simulate LLM finishing (no content)
        chunk2 = %{"choices" => [%{"delta" => %{}}]}
        {:ok, [chunk1, chunk2]}
      end)
      # Expect a SECOND call to LLM with the tool result
      |> expect(:stream_completion, fn history, _opts ->
        # Verify history contains tool result
        last_msg = List.last(history)
        assert last_msg["role"] == "tool"
        assert last_msg["content"] == "Tool Result"
        
        {:ok, [%{"choices" => [%{"delta" => %{"content" => "Done"}}]}]}
      end)

      {:ok, _pid} = Pincer.Core.Executor.start(session_pid, session_id, history, 
        tool_registry: Pincer.MockToolRegistry,
        llm_client: Pincer.MockLLMClient
      )

      assert_receive {:sme_tool_use, "my_tool"}, 1000
      assert_receive {:executor_finished, _, "Done"}, 1000
    end
  end
end
