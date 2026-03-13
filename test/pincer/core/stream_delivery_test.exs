defmodule Pincer.Core.StreamDeliveryTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.StreamDelivery
  alias Pincer.Core.StreamingPolicy

  test "partial sends first preview and stores returned message id" do
    test_pid = self()

    state =
      StreamDelivery.handle_partial(
        %{channel: :x},
        "Hello",
        1_000,
        [
          send: fn text ->
            send(test_pid, {:send, text})
            {:ok, 55}
          end,
          edit: fn _message_id, _text ->
            flunk("edit should not be called on first preview")
          end
        ],
        debounce_ms: 1_000
      )

    assert_receive {:send, "Hello ▌"}
    assert state.message_id == 55
    assert state.buffer == "Hello"
    assert state.last_update == 1_000
  end

  test "partial falls back to send when preview edit fails" do
    test_pid = self()

    state =
      StreamDelivery.handle_partial(
        %{message_id: 10, buffer: "Hello", last_update: 0},
        " world",
        1_500,
        [
          send: fn text ->
            send(test_pid, {:send, text})
            {:ok, 77}
          end,
          edit: fn message_id, text ->
            send(test_pid, {:edit, message_id, text})
            {:error, :rate_limited}
          end
        ],
        debounce_ms: 1_000
      )

    assert_receive {:edit, 10, "Hello world ▌"}
    assert_receive {:send, "Hello world ▌"}
    assert state.message_id == 77
    assert state.buffer == "Hello world"
    assert state.last_update == 1_500
  end

  test "final edits existing preview in place and resets streaming state" do
    test_pid = self()

    state =
      StreamDelivery.handle_final(
        %{channel: :x, message_id: 99, buffer: "Hello", last_update: 1_000},
        "Hello world!",
        send: fn _text ->
          flunk("send should not be called when edit succeeds")
        end,
        edit: fn message_id, text ->
          send(test_pid, {:edit, message_id, text})
          :ok
        end
      )

    assert_receive {:edit, 99, "Hello world!"}
    assert state == Map.merge(%{channel: :x}, StreamingPolicy.initial_state())
  end

  test "final falls back to send when preview edit fails and still resets state" do
    test_pid = self()

    state =
      StreamDelivery.handle_final(
        %{message_id: 99, buffer: "Hello", last_update: 1_000},
        "Hello world!",
        send: fn text ->
          send(test_pid, {:send, text})
          {:ok, 101}
        end,
        edit: fn message_id, text ->
          send(test_pid, {:edit, message_id, text})
          {:error, :gone}
        end
      )

    assert_receive {:edit, 99, "Hello world!"}
    assert_receive {:send, "Hello world!"}
    assert state == StreamingPolicy.initial_state()
  end
end
