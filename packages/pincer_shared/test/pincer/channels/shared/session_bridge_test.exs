defmodule Pincer.Channels.Shared.SessionBridgeTest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.Shared.SessionBridge
  alias PincerPorts.Session.Context

  defmodule PubSubStub do
    @behaviour PincerPorts.PubSub

    @impl true
    def subscribe(topic) do
      if pid = Process.get(:bridge_test_pid), do: send(pid, {:pubsub, :subscribe, topic})
      {:ok, self()}
    end

    @impl true
    def unsubscribe(topic) do
      if pid = Process.get(:bridge_test_pid), do: send(pid, {:pubsub, :unsubscribe, topic})
      :ok
    end

    @impl true
    def broadcast(topic, message) do
      if pid = Process.get(:bridge_test_pid), do: send(pid, {:pubsub, :broadcast, topic, message})
      :ok
    end
  end

  defmodule StreamingStub do
    def status_initial_state, do: %{status_message_id: nil, status_message_text: nil}

    def stream_initial_state,
      do: %{message_id: nil, buffer: "", last_update: 0, preview_suppressed: false}
  end

  defmodule SessionStub do
    def start_session(session_id, opts) do
      if pid = Process.get(:bridge_test_pid),
        do: send(pid, {:session, :start_session, session_id, opts})

      case Process.get(:start_session_result, {:ok, self()}) do
        result -> result
      end
    end

    def ensure_started(session_id, opts) do
      if pid = Process.get(:bridge_test_pid),
        do: send(pid, {:session, :ensure_started, session_id, opts})

      Process.get(:ensure_started_result, {:ok, self()})
    end
  end

  defmodule WorkerServer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(opts), do: {:ok, %{notify: opts[:notify]}}

    @impl true
    def handle_cast({:bind_session, session_id}, state) do
      if state.notify, do: send(state.notify, {:worker_cast, {:bind_session, session_id}})
      {:noreply, state}
    end
  end

  setup do
    registry_name = :"BridgeTestRegistry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    Process.put(:bridge_test_pid, self())

    saved_env = %{
      session_registry: Application.fetch_env(:pincer, :session_registry),
      session_adapter: Application.fetch_env(:pincer, :session_adapter),
      pubsub_adapter: Application.fetch_env(:pincer, :pubsub_adapter),
      streaming_adapter: Application.fetch_env(:pincer, :streaming_adapter)
    }

    Application.put_env(:pincer, :session_registry, registry_name)
    Application.put_env(:pincer, :session_adapter, SessionStub)
    Application.put_env(:pincer, :pubsub_adapter, PubSubStub)
    Application.put_env(:pincer, :streaming_adapter, StreamingStub)

    on_exit(fn ->
      Process.delete(:bridge_test_pid)
      Process.delete(:start_session_result)
      Process.delete(:ensure_started_result)

      Enum.each(saved_env, fn
        {key, {:ok, val}} -> Application.put_env(:pincer, key, val)
        {key, :error} -> Application.delete_env(:pincer, key)
      end)
    end)

    {:ok, registry: registry_name}
  end

  test "worker_key/2 and via_tuple/2-3 build Registry tuples", %{registry: registry} do
    assert SessionBridge.worker_key(:telegram, 42) == "telegram_session_worker_42"

    assert SessionBridge.via_tuple(:telegram, 42) ==
             {:via, Registry, {registry, "telegram_session_worker_42"}}

    assert SessionBridge.via_tuple(:slack, "C123", registry: :custom_reg, key: "C123") ==
             {:via, Registry, {:custom_reg, "C123"}}
  end

  test "session id helpers handle prefixes, defaults, and recipient resolution" do
    assert SessionBridge.default_session_id(:discord, 99) == "discord_99"
    assert SessionBridge.normalize_session_id(:discord, 99, "custom_1") == "custom_1"
    assert SessionBridge.normalize_session_id(:discord, 99, nil) == "discord_99"
    assert SessionBridge.normalize_session_id(:discord, 99, "") == "discord_99"

    assert SessionBridge.handles_session?(:line, "line_U123")
    refute SessionBridge.handles_session?(:line, "slack_C123")

    assert SessionBridge.resolve_recipient(:feishu, "feishu_ou_123") == "ou_123"
    assert SessionBridge.resolve_recipient(:feishu, "other_id") == "other_id"
  end

  test "subscribe/1 and unsubscribe/1 delegate to PincerPorts.PubSub" do
    assert {:ok, _pid} = SessionBridge.subscribe("telegram_42")
    assert_received {:pubsub, :subscribe, "session:telegram_42"}

    assert :ok = SessionBridge.unsubscribe("telegram_42")
    assert_received {:pubsub, :unsubscribe, "session:telegram_42"}
  end

  test "initial_state/2 merges extra and streaming initial state when requested" do
    assert SessionBridge.initial_state(%{chat_id: 1, session_id: "whatsapp_1"}) == %{
             chat_id: 1,
             session_id: "whatsapp_1"
           }

    state =
      SessionBridge.initial_state(%{chat_id: 1, session_id: "telegram_1"},
        streaming: true,
        extra: %{tool_calls: []}
      )

    assert state.chat_id == 1
    assert state.session_id == "telegram_1"
    assert state.tool_calls == []
    assert state.status_message_id == nil
    assert state.buffer == ""
  end

  test "bind_session/2-3 is a no-op for same or invalid ids and rebinds on new id" do
    state = %{chat_id: 1, session_id: "telegram_1", marker: :old}

    assert {:noreply, ^state} = SessionBridge.bind_session(state, "telegram_1")
    refute_received {:pubsub, _, _}

    assert {:noreply, ^state} = SessionBridge.bind_session(state, "")
    assert {:noreply, ^state} = SessionBridge.bind_session(state, nil)
    refute_received {:pubsub, _, _}

    assert {:noreply, %{session_id: "telegram_main", marker: :old}} =
             SessionBridge.bind_session(state, "telegram_main")

    assert_received {:pubsub, :unsubscribe, "session:telegram_1"}
    assert_received {:pubsub, :subscribe, "session:telegram_main"}

    assert {:noreply, %{session_id: "telegram_custom", marker: :rebuilt}} =
             SessionBridge.bind_session(state, "telegram_custom",
               on_rebind: fn s, sid -> %{s | session_id: sid, marker: :rebuilt} end
             )

    assert_received {:pubsub, :unsubscribe, "session:telegram_1"}
    assert_received {:pubsub, :subscribe, "session:telegram_custom"}
  end

  test "ensure_started/2 with Context starts missing session and skips registered ones", %{
    registry: registry
  } do
    context =
      Context.new(
        channel: :telegram,
        session_id: "telegram_55",
        root_agent_id: "agent_55",
        workspace_path: "/tmp/agent_55"
      )

    assert {:ok, _pid} =
             SessionBridge.ensure_started(context,
               on_start: fn sid -> send(self(), {:started_cb, sid}) end
             )

    assert_received {:started_cb, "telegram_55"}
    assert_received {:session, :start_session, "telegram_55", start_opts}
    assert start_opts[:root_agent_id] == "agent_55"
    assert start_opts[:workspace_path] == "/tmp/agent_55"
    refute Keyword.has_key?(start_opts, :session_id)

    Process.put(:start_session_result, {:error, {:already_started, self()}})
    assert :ok = SessionBridge.ensure_started(context, normalize_result?: true)
    assert_received {:session, :start_session, "telegram_55", _}

    Process.put(:start_session_result, {:error, :boom})
    assert {:error, :boom} = SessionBridge.ensure_started(context, normalize_result?: true)
    assert_received {:session, :start_session, "telegram_55", _}

    {:ok, _} = Registry.register(registry, "telegram_55", :present)
    assert :ok = SessionBridge.ensure_started(context)
    refute_received {:session, :start_session, _, _}
  end

  test "ensure_started/2 with binary session_id supports start_session and ensure_started strategies",
       %{registry: registry} do
    assert {:ok, _pid} = SessionBridge.ensure_started("discord_10")
    assert_received {:session, :start_session, "discord_10", []}

    {:ok, _} = Registry.register(registry, "discord_10", :present)
    assert :ok = SessionBridge.ensure_started("discord_10")
    refute_received {:session, :start_session, "discord_10", []}

    assert {:ok, _pid} =
             SessionBridge.ensure_started("slack_C1", strategy: :ensure_started)

    assert_received {:session, :ensure_started, "slack_C1", []}
  end

  test "ensure_started/2 with {channel, recipient_id} starts, rebinds, and respects already_started policy" do
    test_pid = self()

    start_worker = fn recipient_id, _session_id ->
      WorkerServer.start_link(
        name: SessionBridge.via_tuple(:telegram, recipient_id),
        notify: test_pid
      )
    end

    assert {:ok, pid} =
             SessionBridge.ensure_started({:telegram, 100},
               session_id: nil,
               start_worker: start_worker,
               already_started: :error
             )

    assert {:error, {:already_started, ^pid}} =
             SessionBridge.ensure_started({:telegram, 100},
               session_id: "telegram_main",
               start_worker: start_worker,
               already_started: :error
             )

    assert_receive {:worker_cast, {:bind_session, "telegram_main"}}

    assert {:ok, ^pid} =
             SessionBridge.ensure_started({:telegram, 100},
               session_id: "telegram_other",
               start_worker: start_worker,
               already_started: :ok
             )

    assert_receive {:worker_cast, {:bind_session, "telegram_other"}}

    assert :ok =
             SessionBridge.ensure_started({:telegram, 100},
               start_worker: fn _id -> {:error, {:already_started, pid}} end,
               rebind: false,
               already_started: :ok_atom
             )

    refute_receive {:worker_cast, _}, 50

    assert {:error, :failed} =
             SessionBridge.ensure_started({:dingtalk, "u1"},
               session_id: "dingtalk_u1",
               start_worker: fn _id, _sid -> {:error, :failed} end,
               already_started: :ok
             )
  end
end
