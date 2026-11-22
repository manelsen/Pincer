defmodule Pincer.LLM.StreamFallbackTest do
  use ExUnit.Case, async: true

  alias Pincer.LLM.StreamFallback

  describe "chat_message_to_chunks/1" do
    test "turns a text-only message into a single content delta" do
      assert StreamFallback.chat_message_to_chunks(%{"content" => "hello"}) ==
               [%{"choices" => [%{"delta" => %{"content" => "hello"}}]}]
    end

    test "omits the content key when the message has no text" do
      assert StreamFallback.chat_message_to_chunks(%{"tool_calls" => []}) ==
               [%{"choices" => [%{"delta" => %{}}]}]
    end

    test "converts tool calls into indexed stream deltas" do
      message = %{
        "content" => "thinking",
        "tool_calls" => [
          %{
            "id" => "call_1",
            "function" => %{"name" => "my_tool", "arguments" => ~s({"a":1})}
          }
        ]
      }

      assert [%{"choices" => [%{"delta" => delta}]}] =
               StreamFallback.chat_message_to_chunks(message)

      assert delta["content"] == "thinking"

      assert delta["tool_calls"] == [
               %{
                 "index" => 0,
                 "id" => "call_1",
                 "function" => %{"name" => "my_tool", "arguments" => ~s({"a":1})}
               }
             ]
    end

    test "defaults missing function fields to empty strings" do
      message = %{"tool_calls" => [%{"id" => "call_1", "function" => %{}}]}

      assert [%{"choices" => [%{"delta" => delta}]}] =
               StreamFallback.chat_message_to_chunks(message)

      assert [%{"function" => %{"name" => "", "arguments" => ""}}] = delta["tool_calls"]
    end

    test "falls back to an empty delta for non-map input" do
      assert StreamFallback.chat_message_to_chunks(:nope) ==
               [%{"choices" => [%{"delta" => %{"content" => ""}}]}]
    end
  end

  describe "stream_to_chat/5" do
    test "returns the chat message as stream chunks on success" do
      assert {:ok, [%{"choices" => [%{"delta" => %{"content" => "hi"}}]}]} =
               StreamFallback.stream_to_chat(
                 :stream_completion,
                 :unavailable,
                 fn -> {:ok, %{"content" => "hi"}, nil} end,
                 fn reason -> send(self(), {:errored, reason}) end
               )
    end

    test "forwards the failure and records an error when the fallback fails" do
      assert {:error, :backend_down} =
               StreamFallback.stream_to_chat(
                 :stream_completion,
                 :unavailable,
                 fn -> {:error, :backend_down} end,
                 fn reason -> send(self(), {:errored, reason}) end
               )

      assert_received {:errored, :backend_down}
    end

    test "does not retry for a non-streaming action" do
      assert {:error, :unexpected} =
               StreamFallback.stream_to_chat(
                 :chat_completion,
                 :unexpected,
                 fn -> flunk("must not issue a fallback request") end,
                 fn reason -> send(self(), {:errored, reason}) end
               )

      assert_received {:errored, :unexpected}
    end
  end
end
