defmodule Pincer.Core.StreamingPolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.StreamingPolicy

  describe "on_partial/4" do
    test "renders preview on first token with cursor" do
      state = StreamingPolicy.initial_state()
      {new_state, action} = StreamingPolicy.on_partial(state, "Hello", 1_000, debounce_ms: 1_000)

      assert new_state.buffer == "Hello"
      assert action == {:render_preview, "Hello ▌"}
    end

    test "debounces updates while still accumulating buffer" do
      state = %{message_id: 10, buffer: "Hello", last_update: 1_000}

      {new_state, action} = StreamingPolicy.on_partial(state, " world", 1_200, debounce_ms: 1_000)

      assert new_state.buffer == "Hello world"
      assert action == :noop
    end
  end

  describe "on_final/2" do
    test "edits existing preview message and removes cursor" do
      state = %{message_id: 77, buffer: "Hello", last_update: 1_000}

      {reset_state, action} = StreamingPolicy.on_final(state, "Hello world!")

      assert action == {:edit_final, 77, "Hello world!"}
      assert reset_state == StreamingPolicy.initial_state()
    end

    test "sends a single final message when preview does not exist" do
      state = StreamingPolicy.initial_state()

      {reset_state, action} = StreamingPolicy.on_final(state, "Only final")

      assert action == {:send_final, "Only final"}
      assert reset_state == StreamingPolicy.initial_state()
    end

    test "falls back to buffered text when final payload comes empty" do
      state = %{message_id: 13, buffer: "Buffered", last_update: 10}

      {_reset_state, action} = StreamingPolicy.on_final(state, "   ")

      assert action == {:edit_final, 13, "Buffered"}
    end
  end
end
