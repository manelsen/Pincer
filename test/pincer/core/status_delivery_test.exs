defmodule Pincer.Core.StatusDeliveryTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.StatusDelivery

  test "sends first status message and stores returned id" do
    test_pid = self()

    state =
      StatusDelivery.deliver(
        %{chat_id: 1},
        "running",
        send: fn text ->
          send(test_pid, {:send, text})
          {:ok, 11}
        end,
        edit: fn _message_id, _text ->
          flunk("edit should not run on first status send")
        end
      )

    assert_receive {:send, "running"}
    assert state.status_message_id == 11
    assert state.status_message_text == "running"
  end

  test "edits existing status message in place" do
    test_pid = self()

    state =
      StatusDelivery.deliver(
        %{status_message_id: 11, status_message_text: "running", chat_id: 1},
        "finished",
        send: fn _text ->
          flunk("send should not run when edit succeeds")
        end,
        edit: fn message_id, text ->
          send(test_pid, {:edit, message_id, text})
          :ok
        end
      )

    assert_receive {:edit, 11, "finished"}
    assert state.status_message_id == 11
    assert state.status_message_text == "finished"
  end

  test "falls back to send when status edit fails" do
    test_pid = self()

    state =
      StatusDelivery.deliver(
        %{status_message_id: 11, status_message_text: "running", chat_id: 1},
        "finished",
        send: fn text ->
          send(test_pid, {:send, text})
          {:ok, 22}
        end,
        edit: fn message_id, text ->
          send(test_pid, {:edit, message_id, text})
          {:error, :gone}
        end
      )

    assert_receive {:edit, 11, "finished"}
    assert_receive {:send, "finished"}
    assert state.status_message_id == 22
    assert state.status_message_text == "finished"
  end

  test "returns original state when policy resolves to noop" do
    state = %{status_message_id: 11, status_message_text: "running", chat_id: 1}

    assert StatusDelivery.deliver(
             state,
             "running",
             send: fn _text -> flunk("send should not run on noop") end,
             edit: fn _message_id, _text -> flunk("edit should not run on noop") end
           ) == state
  end
end
