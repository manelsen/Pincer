defmodule Pincer.Infra.PubSubTest do
  use ExUnit.Case, async: true

  alias Pincer.Infra.PubSub
  alias Pincer.Ports.PubSub, as: ChannelPubSub

  defmodule TestChannel do
    use PincerPorts.Channel
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
    channel = start_supervised!({TestChannel, %{}})

    assert {channel, []} in Registry.lookup(Pincer.Infra.PubSub.Registry, "system:delivery")
  end
end
