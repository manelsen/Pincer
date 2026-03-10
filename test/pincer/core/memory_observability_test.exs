defmodule Pincer.Core.MemoryObservabilityTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.MemoryObservability
  alias Pincer.Core.Telemetry

  setup do
    Application.ensure_all_started(:pincer)
    :ok = MemoryObservability.reset()
    :ok
  end

  test "snapshot/0 returns stable defaults after reset" do
    snapshot = MemoryObservability.snapshot()

    assert snapshot.recall.count == 0
    assert snapshot.recall.avg_duration_ms == 0.0
    assert snapshot.recall.total_hits == 0
    assert snapshot.search.count == 0
    assert snapshot.search.avg_duration_ms == 0.0
    assert snapshot.search.by_source == %{}
    assert snapshot.last_recall == nil
    assert snapshot.last_search == nil
  end

  test "aggregates memory search and recall telemetry into snapshot" do
    Telemetry.emit_memory_search(%{duration_ms: 10, hit_count: 2}, %{
      source: :messages,
      outcome: :ok,
      session_id: "s-1",
      query_length: 20
    })

    Telemetry.emit_memory_search(%{duration_ms: 4, hit_count: 0}, %{
      source: :semantic,
      outcome: :skipped,
      session_id: "s-1",
      query_length: 20
    })

    Telemetry.emit_memory_recall(
      %{
        duration_ms: 18,
        total_hits: 2,
        message_hits: 2,
        document_hits: 0,
        semantic_hits: 0,
        prompt_chars: 120,
        learnings_count: 1
      },
      %{eligible: true, session_id: "s-1", query_length: 20}
    )

    snapshot = MemoryObservability.snapshot()

    assert snapshot.search.count == 2
    assert snapshot.search.total_hits == 2
    assert snapshot.search.avg_duration_ms == 7.0
    assert snapshot.search.by_source.messages.count == 1
    assert snapshot.search.by_source.messages.total_hits == 2
    assert snapshot.search.by_source.semantic.skipped_count == 1

    assert snapshot.recall.count == 1
    assert snapshot.recall.eligible_count == 1
    assert snapshot.recall.total_hits == 2
    assert snapshot.recall.prompt_chars == 120
    assert snapshot.recall.learnings_count == 1
    assert snapshot.recall.avg_duration_ms == 18.0

    assert snapshot.last_search.source == :semantic
    assert snapshot.last_search.outcome == :skipped
    assert snapshot.last_recall.session_id == "s-1"
    assert snapshot.last_recall.total_hits == 2
  end
end
