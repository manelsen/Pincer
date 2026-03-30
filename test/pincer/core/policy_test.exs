defmodule Pincer.Core.PolicyTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AccessPolicy
  alias Pincer.Core.ChannelEventPolicy
  alias Pincer.Core.EmptyResponseRecoveryPolicy
  alias Pincer.Core.Policy
  alias Pincer.Core.RetryPolicy
  alias Pincer.Core.SessionScopePolicy
  alias Pincer.Core.StatusMessagePolicy
  alias Pincer.Core.StreamingPolicy
  alias Pincer.Core.TurnOutcomePolicy

  describe "allow?/2" do
    test "delegates dm access decisions to AccessPolicy" do
      attrs = %{channel: :telegram, sender_id: 123, config: %{}}
      assert Policy.allow?(:dm_access, attrs) == AccessPolicy.authorize_dm(:telegram, 123, %{})
    end
  end

  describe "route/2" do
    test "delegates session scope resolution to SessionScopePolicy" do
      attrs = %{channel: :telegram, context: %{chat_id: "42", chat_type: "private"}, config: %{}}

      assert Policy.route(:session_scope, attrs) ==
               SessionScopePolicy.resolve(:telegram, attrs.context, %{})
    end
  end

  describe "budget/2" do
    test "delegates retry-after budget parsing to RetryPolicy" do
      reason = {:http_error, 429, "rate", %{retry_after_ms: 3_000}}
      attrs = %{reason: reason, elapsed_ms: 1_000, max_elapsed_ms: 10_000}

      assert Policy.budget(:retry_after_ms, attrs) ==
               RetryPolicy.retry_after_ms(reason, 1_000, 10_000)
    end
  end

  describe "guard!/2" do
    test "delegates approval message formatting to ChannelEventPolicy" do
      attrs = %{channel: :telegram, command: "mix test"}

      assert Policy.guard!(:approval_message, attrs) ==
               ChannelEventPolicy.approval_message(:telegram, "mix test")
    end

    test "delegates status action computation to StatusMessagePolicy" do
      state = StatusMessagePolicy.initial_state()
      attrs = %{state: state, text: "Running..."}
      assert Policy.guard!(:status_message, attrs) == {:send, "Running..."}
    end

    test "delegates streaming transitions to StreamingPolicy" do
      state = StreamingPolicy.initial_state()
      attrs = %{state: state, token: "Hi", now_ms: 0}

      assert Policy.guard!(:stream_partial, attrs) ==
               StreamingPolicy.on_partial(state, "Hi", 0, [])

      assert Policy.guard!(:stream_final, %{state: state, final_text: "Done"}) ==
               StreamingPolicy.on_final(state, "Done")
    end
  end

  describe "recover/2" do
    test "delegates empty response recovery prompt and retry history" do
      assert Policy.recover(:empty_response_prompt, %{}) ==
               EmptyResponseRecoveryPolicy.recovery_prompt()

      history = [%{"role" => "user", "content" => "Oi"}]

      assert Policy.recover(:empty_response_history, %{history: history}) ==
               EmptyResponseRecoveryPolicy.retry_history(history)
    end

    test "delegates turn outcome resolution" do
      attrs = %{final_text: "done", streamed_text: nil, tool_messages: []}
      assert Policy.recover(:turn_outcome, %{attrs: attrs}) == TurnOutcomePolicy.resolve(attrs)
    end
  end
end
