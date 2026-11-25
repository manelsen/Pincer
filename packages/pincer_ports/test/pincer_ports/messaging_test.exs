defmodule PincerPorts.MessagingTest do
  use ExUnit.Case, async: false

  alias PincerPorts.Messaging

  defmodule Adapter do
    @behaviour Messaging

    @impl true
    def deliver(session_id, text) do
      send(self(), {:delivered, session_id, text})
      :ok
    end

    @impl true
    def send_message(channel, recipient, text, opts) do
      send(self(), {:message, channel, recipient, text, opts})
      {:ok, "message-id"}
    end

    @impl true
    def send_file(channel, recipient, file, caption) do
      send(self(), {:file, channel, recipient, file, caption})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:pincer, :messaging_adapter)
    Application.put_env(:pincer, :messaging_adapter, Adapter)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:pincer, :messaging_adapter, adapter)
        :error -> Application.delete_env(:pincer, :messaging_adapter)
      end
    end)
  end

  test "dispatches session delivery, text, attachments, and replies through one adapter" do
    assert :ok = Messaging.deliver("session", "update")
    assert_received {:delivered, "session", "update"}

    assert {:ok, "message-id"} = Messaging.send_message(:telegram, "recipient", "update")
    assert_received {:message, :telegram, "recipient", "update", []}

    file = %{name: "note.txt", path: "/workspace/note.txt", body: "note"}
    assert :ok = Messaging.send_file(:discord, "recipient", file, "caption")
    assert_received {:file, :discord, "recipient", ^file, "caption"}

    assert {:ok, "message-id"} = Messaging.reply_to(:telegram, "recipient", "original", "reply")
    assert_received {:message, :telegram, "recipient", "reply", [reply_to_message_id: "original"]}
  end

  test "requires a configured messaging adapter" do
    Application.delete_env(:pincer, :messaging_adapter)

    assert_raise ArgumentError, ~r/:messaging_adapter/, fn ->
      Messaging.deliver("session", "update")
    end
  end
end
