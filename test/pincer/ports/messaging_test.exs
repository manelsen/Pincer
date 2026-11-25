defmodule Pincer.Ports.MessagingTest do
  use ExUnit.Case, async: false

  alias Pincer.Ports.Messaging

  defmodule TestPubSub do
    def broadcast(topic, message) do
      send(self(), {:broadcast, topic, message})
      :ok
    end
  end

  test "the root facade publishes session messages on the delivery topic" do
    previous = Application.fetch_env(:pincer, :pubsub_adapter)
    Application.put_env(:pincer, :pubsub_adapter, TestPubSub)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:pincer, :pubsub_adapter, adapter)
        :error -> Application.delete_env(:pincer, :pubsub_adapter)
      end
    end)

    assert :ok = Messaging.deliver("session", "message")
    assert_received {:broadcast, "system:delivery", {:deliver_message, "session", "message"}}
  end
end
