defmodule Pincer.Ports.MessagingTest do
  use ExUnit.Case, async: false

  alias Pincer.Ports.Messaging

  defmodule TestAdapter do
    @behaviour Messaging

    @impl true
    def deliver(session_id, text) do
      send(self(), {:deliver, session_id, text})
      :ok
    end

    @impl true
    def send_message(channel, recipient, text, opts) do
      send(self(), {:send_message, channel, recipient, text, opts})
      {:ok, "msg-1"}
    end

    @impl true
    def send_file(channel, recipient, file, caption) do
      send(self(), {:send_file, channel, recipient, file, caption})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:pincer, :messaging_adapter)
    Application.put_env(:pincer, :messaging_adapter, TestAdapter)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:pincer, :messaging_adapter, adapter)
        :error -> Application.delete_env(:pincer, :messaging_adapter)
      end
    end)

    :ok
  end

  test "dispatches deliver, send_message, send_file, and reply_to through configured adapter" do
    assert :ok = Messaging.deliver("session", "message")
    assert_received {:deliver, "session", "message"}

    assert {:ok, "msg-1"} = Messaging.send_message(:telegram, "123", "hello")
    assert_received {:send_message, :telegram, "123", "hello", []}

    assert {:ok, "msg-1"} = Messaging.send_message(:discord, "456", "hi", silent: true)
    assert_received {:send_message, :discord, "456", "hi", [silent: true]}

    file = %{name: "note.txt", body: "data", path: "/tmp/note.txt"}
    assert :ok = Messaging.send_file(:discord, "456", file, "caption")
    assert_received {:send_file, :discord, "456", ^file, "caption"}

    assert {:ok, "msg-1"} = Messaging.reply_to(:telegram, "123", "42", "ack")
    assert_received {:send_message, :telegram, "123", "ack", [reply_to_message_id: "42"]}
  end
end
