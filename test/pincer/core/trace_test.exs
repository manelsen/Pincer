defmodule Pincer.Core.TraceTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Trace

  test "new/3 builds a trace envelope with empty steps" do
    trace = Trace.new("session-1", "turn-1", %{request_id: "req-1"})

    assert trace.session_id == "session-1"
    assert trace.turn_id == "turn-1"
    assert is_binary(trace.trace_id)
    assert trace.steps == []
    assert trace.metadata.request_id == "req-1"
  end

  test "add_step/5 appends typed steps with details and timestamp" do
    trace =
      Trace.new("session-2", "turn-2")
      |> Trace.add_step(:policy, "llm_route", %{decision: :primary})
      |> Trace.add_step(:llm, "provider_call", %{provider: "openrouter", model: "x"})
      |> Trace.add_step(:tool, "web_fetch", %{result_summary: "ok"})

    assert Enum.map(trace.steps, & &1.kind) == [:policy, :llm, :tool]
    assert Enum.at(trace.steps, 0).name == "llm_route"
    assert Enum.at(trace.steps, 1).details.provider == "openrouter"
    assert is_struct(Enum.at(trace.steps, 2).at, DateTime)
  end

  test "to_checkpoint_metadata/1 serializes trace for checkpoint metadata" do
    trace =
      Trace.new("session-3", "turn-3")
      |> Trace.add_step(:memory, "save", %{memory_id: "m-1"})

    metadata = Trace.to_checkpoint_metadata(trace)

    assert metadata["trace"]["session_id"] == "session-3"
    assert metadata["trace"]["turn_id"] == "turn-3"
    assert length(metadata["trace"]["steps"]) == 1
    assert hd(metadata["trace"]["steps"])["kind"] == "memory"
  end
end
