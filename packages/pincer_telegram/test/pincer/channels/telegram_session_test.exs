defmodule Pincer.Channels.Telegram.SessionTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Channels.Telegram.APIMock
  alias Pincer.Channels.Telegram.Session

  defmodule TestPubSub do
    @behaviour PincerPorts.PubSub

    @impl true
    def subscribe(topic), do: Registry.register(__MODULE__, topic, nil)

    @impl true
    def unsubscribe(topic), do: Registry.unregister(__MODULE__, topic)

    @impl true
    def broadcast(topic, message) do
      Registry.dispatch(__MODULE__, topic, fn entries ->
        Enum.each(entries, fn {pid, _value} -> send(pid, message) end)
      end)
    end
  end

  defmodule InitialStreamingState do
    def stream_initial_state, do: %{}
    def status_initial_state, do: %{}
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: SessionRegistry}, id: :session_registry)
    start_supervised!({Registry, keys: :duplicate, name: TestPubSub}, id: :pubsub_registry)

    settings = [
      pubsub_adapter: TestPubSub,
      session_registry: SessionRegistry,
      streaming_adapter: InitialStreamingState,
      telegram_api: APIMock
    ]

    previous = Enum.map(settings, fn {key, _} -> {key, Application.fetch_env(:pincer, key)} end)
    Application.put_all_env(pincer: settings)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:pincer, key, value)
        {key, :error} -> Application.delete_env(:pincer, key)
      end)
    end)

    verify_on_exit!()
    :ok
  end

  test "starts and delivers through configured ports without the Pincer host app" do
    refute Code.ensure_loaded?(Pincer.Application)
    test_pid = self()

    expect(APIMock, :send_message, fn "42", "Standalone reply", opts ->
      assert opts[:parse_mode] == "HTML"
      send(test_pid, :reply_sent)
      {:ok, %{message_id: 123}}
    end)

    worker = start_supervised!({Session, 42})
    allow(APIMock, self(), worker)

    assert [{^worker, nil}] = Registry.lookup(TestPubSub, "session:telegram_42")

    assert :ok =
             TestPubSub.broadcast(
               "system:delivery",
               {:deliver_message, "telegram_42", "Standalone reply"}
             )

    assert_receive :reply_sent, 1_000
  end

  test "rebinds an existing worker to the newly selected topic" do
    worker = start_supervised!({Session, 43})

    assert {:error, {:already_started, ^worker}} = Session.ensure_started(43, "telegram_main")
    assert %{session_id: "telegram_main"} = :sys.get_state(worker)
    assert Registry.lookup(TestPubSub, "session:telegram_43") == []
    assert [{^worker, nil}] = Registry.lookup(TestPubSub, "session:telegram_main")
  end
end
