defmodule Pincer.Core.ConversationObservabilityTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.ConversationObservability
  alias Pincer.Core.Telemetry

  setup do
    ConversationObservability.reset()
    :ok
  end

  test "initial snapshot has zero counters" do
    snap = ConversationObservability.snapshot()
    assert snap.active_sessions == 0
    assert snap.sessions_started == 0
    assert snap.sessions_stopped == 0
    assert snap.turns_completed == 0
    assert snap.turns_errored == 0
    assert snap.total_prompt_tokens == 0
    assert snap.total_completion_tokens == 0
    assert snap.total_turn_duration_ms == 0
    assert snap.last_turn_duration_ms == nil
  end

  test "session start increments sessions_started and active_sessions" do
    Telemetry.emit_conversation_start("s-obs-1")
    Process.sleep(10)

    snap = ConversationObservability.snapshot()
    assert snap.sessions_started >= 1
    assert snap.active_sessions >= 1
  end

  test "session stop increments sessions_stopped" do
    Telemetry.emit_conversation_start("s-obs-2")
    Telemetry.emit_conversation_stop("s-obs-2")
    Process.sleep(10)

    snap = ConversationObservability.snapshot()
    assert snap.sessions_started >= 1
    assert snap.sessions_stopped >= 1
  end

  test "active_sessions = started - stopped" do
    ConversationObservability.reset()

    Telemetry.emit_conversation_start("s-obs-3a")
    Telemetry.emit_conversation_start("s-obs-3b")
    Telemetry.emit_conversation_stop("s-obs-3a")
    Process.sleep(20)

    snap = ConversationObservability.snapshot()
    assert snap.active_sessions == snap.sessions_started - snap.sessions_stopped
  end

  test "turn stop updates turns_completed and token counts" do
    ConversationObservability.reset()
    start_ms = Telemetry.emit_conversation_turn_start("s-obs-4")
    Process.sleep(5)

    Telemetry.emit_conversation_turn_stop("s-obs-4", start_ms, %{
      prompt_tokens: 100,
      completion_tokens: 50
    })

    Process.sleep(20)
    snap = ConversationObservability.snapshot()
    assert snap.turns_completed == 1
    assert snap.total_prompt_tokens == 100
    assert snap.total_completion_tokens == 50
    assert snap.total_turn_duration_ms >= 0
    assert is_integer(snap.last_turn_duration_ms)
  end

  test "turn error increments turns_errored" do
    ConversationObservability.reset()
    Telemetry.emit_conversation_error("s-obs-5", :some_error)
    Process.sleep(20)

    snap = ConversationObservability.snapshot()
    assert snap.turns_errored == 1
  end

  test "reset clears all counters" do
    Telemetry.emit_conversation_start("s-obs-reset")
    Process.sleep(10)

    ConversationObservability.reset()
    snap = ConversationObservability.snapshot()

    assert snap.sessions_started == 0
    assert snap.active_sessions == 0
    assert snap.turns_completed == 0
  end

  test "multiple turns accumulate token totals" do
    ConversationObservability.reset()

    for i <- 1..3 do
      start_ms = Telemetry.emit_conversation_turn_start("s-obs-multi")

      Telemetry.emit_conversation_turn_stop("s-obs-multi", start_ms, %{
        prompt_tokens: i * 10,
        completion_tokens: i * 5
      })
    end

    Process.sleep(30)
    snap = ConversationObservability.snapshot()

    assert snap.turns_completed == 3
    assert snap.total_prompt_tokens == 60
    assert snap.total_completion_tokens == 30
  end
end
