defmodule Pincer.LLM.Providers.OpenAICompatTest do
  use ExUnit.Case, async: true

  alias Pincer.LLM.Providers.OpenAICompat

  describe "build_request_body/5 token budget" do
    test "injects explicit max_tokens with context-aware clamp" do
      messages = [%{"role" => "user", "content" => String.duplicate("a", 6_000)}]

      body =
        OpenAICompat.build_request_body(
          messages,
          "test-model",
          [],
          %{
            context_window: 2_000,
            context_reserve_tokens: 200,
            default_max_tokens: 4_096
          },
          false
        )

      assert body[:max_tokens] > 0
      assert body[:max_tokens] <= 300
    end

    test "prefers max_completion_tokens when configured and clamps safely" do
      messages = [%{"role" => "user", "content" => String.duplicate("b", 6_000)}]

      body =
        OpenAICompat.build_request_body(
          messages,
          "test-model",
          [],
          %{
            context_window: 2_000,
            context_reserve_tokens: 200,
            max_completion_tokens: 999
          },
          false
        )

      assert body[:max_completion_tokens] > 0
      assert body[:max_completion_tokens] <= 300
      refute Map.has_key?(body, :max_tokens)
    end
  end

  describe "message_to_stream_chunks/1" do
    test "omits synthetic content when tool calls are present" do
      chunks =
        OpenAICompat.message_to_stream_chunks(%{
          "role" => "assistant",
          "content" => "ok",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "function" => %{"name" => "tool_a", "arguments" => "{\"k\":1}"}
            }
          ]
        })

      assert is_list(chunks)
      assert get_in(chunks, [Access.at(0), "choices", Access.at(0), "delta", "content"]) == nil

      assert get_in(chunks, [
               Access.at(0),
               "choices",
               Access.at(0),
               "delta",
               "tool_calls",
               Access.at(0),
               "function",
               "name"
             ]) == "tool_a"
    end

    test "keeps content when no tool calls are present" do
      chunks =
        OpenAICompat.message_to_stream_chunks(%{
          "role" => "assistant",
          "content" => "ok"
        })

      assert get_in(chunks, [Access.at(0), "choices", Access.at(0), "delta", "content"]) == "ok"
    end
  end
end
