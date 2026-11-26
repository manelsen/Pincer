defmodule Pincer.Core.Session.InputBufferTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Session.InputBuffer
  alias PincerPorts.Structs.IncomingMessage

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "sess-buf-1",
        status: :idle,
        input_buffer: [],
        debounce_timer: nil
      },
      overrides
    )
  end

  describe "enqueue/3" do
    test "buffers input and schedules flush timer when idle" do
      state = base_state()

      new_state =
        InputBuffer.enqueue(state, "hello",
          debounce_ms: 500,
          timer_send_fn: fn ms ->
            send(self(), {:scheduled, ms})
            :fake_timer_1
          end,
          publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end
        )

      assert new_state.input_buffer == ["hello"]
      assert new_state.debounce_timer == :fake_timer_1
      assert_received {:scheduled, 500}
      refute_received {:published, _, _}
    end

    test "cancels prior debounce timer and notifies busy status when working" do
      state =
        base_state(%{
          status: :working,
          input_buffer: ["first"],
          debounce_timer: :old_timer
        })

      new_state =
        InputBuffer.enqueue(state, "second",
          timer_cancel_fn: fn ref -> send(self(), {:cancelled, ref}) end,
          timer_send_fn: fn _ms -> :new_timer end,
          publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end
        )

      assert new_state.input_buffer == ["first", "second"]
      assert new_state.debounce_timer == :new_timer
      assert_received {:cancelled, :old_timer}
      assert_received {:published, "sess-buf-1", {:agent_status, status_msg}}
      assert status_msg =~ "Mensagem recebida"
    end
  end

  describe "flush/1" do
    test "joins buffered strings and IncomingMessages and clears buffer and timer" do
      state =
        base_state(%{
          input_buffer: ["line 1", IncomingMessage.new("sess-buf-1", "line 2")],
          debounce_timer: :timer_ref
        })

      assert {"line 1\nline 2", cleared} = InputBuffer.flush(state)
      assert cleared.input_buffer == []
      assert cleared.debounce_timer == nil
    end
  end

  describe "clear/2" do
    test "cancels active timer and resets buffer" do
      state = base_state(%{input_buffer: ["x"], debounce_timer: :t1})

      cleared =
        InputBuffer.clear(state,
          timer_cancel_fn: fn ref -> send(self(), {:cancelled, ref}) end
        )

      assert_received {:cancelled, :t1}
      assert cleared.input_buffer == []
      assert cleared.debounce_timer == nil
    end

    test "is a no-op on timer cancellation when timer is nil" do
      state = base_state(%{input_buffer: ["x"], debounce_timer: nil})

      cleared =
        InputBuffer.clear(state,
          timer_cancel_fn: fn ref -> send(self(), {:cancelled, ref}) end
        )

      refute_received {:cancelled, _}
      assert cleared.input_buffer == []
      assert cleared.debounce_timer == nil
    end
  end
end
