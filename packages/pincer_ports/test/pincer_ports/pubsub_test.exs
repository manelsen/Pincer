defmodule PincerPorts.PubSubTest do
  use ExUnit.Case, async: false

  alias PincerPorts.PubSub

  defmodule TestAdapter do
    @behaviour PubSub

    @impl PubSub
    def subscribe(topic) do
      send(self(), {:subscribe, topic})
      {:ok, self()}
    end

    @impl PubSub
    def broadcast(topic, message) do
      send(self(), {:broadcast, topic, message})
      :ok
    end

    @impl PubSub
    def unsubscribe(topic) do
      send(self(), {:unsubscribe, topic})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:pincer, :pubsub_adapter)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:pincer, :pubsub_adapter, adapter)
        :error -> Application.delete_env(:pincer, :pubsub_adapter)
      end
    end)
  end

  test "dispatches PubSub operations to the host adapter" do
    Application.put_env(:pincer, :pubsub_adapter, TestAdapter)
    caller = self()

    assert {:ok, ^caller} = PubSub.subscribe("session:cli_user")
    assert_received {:subscribe, "session:cli_user"}
    assert :ok = PubSub.broadcast("session:cli_user", {:agent_response, "ready"})
    assert_received {:broadcast, "session:cli_user", {:agent_response, "ready"}}
    assert :ok = PubSub.unsubscribe("session:cli_user")
    assert_received {:unsubscribe, "session:cli_user"}
  end

  test "reports missing and invalid adapter configuration" do
    Application.delete_env(:pincer, :pubsub_adapter)
    assert_raise ArgumentError, ~r/:pubsub_adapter/, fn -> PubSub.subscribe("system:delivery") end

    Application.put_env(:pincer, :pubsub_adapter, nil)
    assert_raise ArgumentError, ~r/:pubsub_adapter/, fn -> PubSub.subscribe("system:delivery") end
  end
end
