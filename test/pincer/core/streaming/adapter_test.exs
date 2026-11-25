defmodule Pincer.Core.Streaming.AdapterTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Streaming.Adapter

  defmodule Stub do
    @behaviour PincerPorts.Streaming

    def stream_initial_state, do: {:stream_initial_state}
    def stream_extract(assigns), do: {:stream_extract, assigns}
    def stream_assign(assigns, state), do: {:stream_assign, assigns, state}

    def stream_on_partial(state, token, now_ms, opts),
      do: {:stream_on_partial, state, token, now_ms, opts}

    def stream_mark_rendered(state, message_id, now_ms),
      do: {:stream_mark_rendered, state, message_id, now_ms}

    def stream_on_final(state, text), do: {:stream_on_final, state, text}

    def handle_partial(state, token, now_ms, transport, opts),
      do: {:handle_partial, state, token, now_ms, transport, opts}

    def handle_final(state, text, transport), do: {:handle_final, state, text, transport}
    def status_initial_state, do: {:status_initial_state}
    def status_next_action(state, text), do: {:status_next_action, state, text}

    def status_mark_sent(state, message_id, text),
      do: {:status_mark_sent, state, message_id, text}

    def status_mark_edited(state, text), do: {:status_mark_edited, state, text}
    def deliver_status(state, text, transport), do: {:deliver_status, state, text, transport}
    def progress_apply_event(tracker, event), do: {:progress_apply_event, tracker, event}
    def progress_render_dashboard(tracker), do: {:progress_render_dashboard, tracker}

    def progress_notifications(messages, tracker),
      do: {:progress_notifications, messages, tracker}
  end

  test "implements the Streaming behaviour and its callbacks" do
    behaviours =
      Adapter.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert PincerPorts.Streaming in behaviours

    for {fun, arity} <- PincerPorts.Streaming.behaviour_info(:callbacks) do
      assert function_exported?(Adapter, fun, arity),
             "Adapter does not implement #{fun}/#{arity}"
    end
  end

  test "the test double covers every port callback" do
    for {fun, arity} <- PincerPorts.Streaming.behaviour_info(:callbacks) do
      assert function_exported?(Stub, fun, arity),
             "Stub does not implement #{fun}/#{arity} - update it with the port"
    end
  end

  test "stream_on_partial/4 returns the next state together with its action" do
    result = Adapter.stream_on_partial(Adapter.stream_initial_state(), "a", 0, [])

    assert {state, action} = result
    assert is_map(state)
    assert state.buffer == "a"
    assert action == {:render_preview, "a ▌"}
  end

  test "handle_partial/5 returns the updated assigns map" do
    result =
      Adapter.handle_partial(
        %{},
        "a",
        0,
        [send: fn _ -> {:ok, 1} end, edit: fn _, _ -> :ok end],
        []
      )

    assert is_map(result)
    assert result.message_id == 1
    assert result.buffer == "a"
    assert result.last_update == 0
  end

  test "status_next_action/2 returns a send action with the text" do
    assert Adapter.status_next_action(Adapter.status_initial_state(), "x") == {:send, "x"}
  end

  test "progress_apply_event/2 returns the tracker map keyed by agent" do
    result = Adapter.progress_apply_event(%{}, %{agent_id: "a", kind: :started})

    assert is_map(result)
    assert %{started?: true, state: :running} = result["a"]
  end

  describe "port dispatch" do
    setup do
      previous = Application.get_env(:pincer, :streaming_adapter)
      Application.put_env(:pincer, :streaming_adapter, Stub)
      on_exit(fn -> restore(previous) end)
      :ok
    end

    test "routes every operation through the configured adapter" do
      state = %{buffer: "s"}

      assert Pincer.Ports.Streaming.stream_initial_state() == {:stream_initial_state}
      assert Pincer.Ports.Streaming.stream_extract(state) == {:stream_extract, state}
      assert Pincer.Ports.Streaming.stream_assign(state, state) == {:stream_assign, state, state}

      assert Pincer.Ports.Streaming.stream_on_partial(state, "a", 0) ==
               {:stream_on_partial, state, "a", 0, []}

      assert Pincer.Ports.Streaming.stream_mark_rendered(state, 1, 2) ==
               {:stream_mark_rendered, state, 1, 2}

      assert Pincer.Ports.Streaming.stream_on_final(state, "t") == {:stream_on_final, state, "t"}

      assert Pincer.Ports.Streaming.handle_partial(state, "a", 0, :telegram, send: true) ==
               {:handle_partial, state, "a", 0, :telegram, [send: true]}

      assert Pincer.Ports.Streaming.handle_final(state, "t", :telegram) ==
               {:handle_final, state, "t", :telegram}

      assert Pincer.Ports.Streaming.status_initial_state() == {:status_initial_state}

      assert Pincer.Ports.Streaming.status_next_action(state, "t") ==
               {:status_next_action, state, "t"}

      assert Pincer.Ports.Streaming.status_mark_sent(state, 1, "t") ==
               {:status_mark_sent, state, 1, "t"}

      assert Pincer.Ports.Streaming.status_mark_edited(state, "t") ==
               {:status_mark_edited, state, "t"}

      assert Pincer.Ports.Streaming.deliver_status(state, "t", :telegram) ==
               {:deliver_status, state, "t", :telegram}

      assert Pincer.Ports.Streaming.progress_apply_event(state, %{}) ==
               {:progress_apply_event, state, %{}}

      assert Pincer.Ports.Streaming.progress_render_dashboard(state) ==
               {:progress_render_dashboard, state}

      assert Pincer.Ports.Streaming.progress_notifications([], state) ==
               {:progress_notifications, [], state}
    end
  end

  defp restore(nil), do: Application.delete_env(:pincer, :streaming_adapter)
  defp restore(value), do: Application.put_env(:pincer, :streaming_adapter, value)
end
