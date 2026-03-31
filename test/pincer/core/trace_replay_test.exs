defmodule Pincer.Core.TraceReplayTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Trace
  alias Pincer.Core.TraceReplay

  test "replay returns deterministic summary without executing tools" do
    trace =
      Trace.new("session-r1", "turn-r1")
      |> Trace.add_step(:policy, "llm_route", %{decision: :primary})
      |> Trace.add_step(:llm, "provider_call", %{provider: "openrouter", model: "x"})
      |> Trace.add_step(:tool, "web_fetch", %{
        args: %{"url" => "https://example.com"},
        result_summary: "ok"
      })

    replay = TraceReplay.replay(trace)

    assert replay.mode == :no_side_effects
    assert replay.steps_replayed == 3
    assert replay.executed_tools == []
    assert replay.stopped_at == :end
  end

  test "replay can stop at tool boundary" do
    trace =
      Trace.new("session-r2", "turn-r2")
      |> Trace.add_step(:policy, "allow", %{decision: :allow})
      |> Trace.add_step(:tool, "git_inspect", %{
        args: %{"action" => "status"},
        result_summary: "clean"
      })
      |> Trace.add_step(:llm, "finalize", %{provider: "z_ai", model: "glm"})

    replay = TraceReplay.replay(trace, stop_at: :tool_boundary)

    assert replay.stopped_at == :tool_boundary
    assert replay.steps_replayed == 2
    assert replay.executed_tools == []
  end
end
