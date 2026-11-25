defmodule Pincer.Infra.PubSubTest do
  use ExUnit.Case, async: true

  alias Pincer.Infra.PubSub
  alias Pincer.Ports.PubSub, as: ChannelPubSub

  defmodule TestChannel do
    use PincerPorts.Channel

    @impl PincerPorts.Channel
    def send_message(recipient_id, message) do
      send(:pincer_pubsub_probe, {:delivered, recipient_id, message})
      :ok
    end

    @impl PincerPorts.Channel
    def handles_session?(session_id), do: session_id == "probe_session"

    @impl PincerPorts.Channel
    def resolve_recipient("probe_session"), do: "probe"
  end

  test "the root port and infrastructure deliver on the same topics" do
    topic = "pubsub:test:#{System.unique_integer([:positive])}"
    assert {:ok, _} = ChannelPubSub.subscribe(topic)

    assert :ok = PubSub.broadcast(topic, {:event, 1})
    assert_received {:event, 1}

    assert :ok = ChannelPubSub.broadcast(topic, {:event, 2})
    assert_received {:event, 2}

    assert :ok = ChannelPubSub.unsubscribe(topic)
    assert :ok = PubSub.broadcast(topic, {:event, 3})
    refute_received {:event, 3}
  end

  test "the shared channel macro still subscribes to outbound delivery" do
    Process.register(self(), :pincer_pubsub_probe)
    start_supervised!({TestChannel, %{}})

    assert :ok = PubSub.broadcast("system:delivery", {:deliver_message, "probe_session", "ready"})
    assert_receive {:delivered, "probe", "ready"}
  end
end
