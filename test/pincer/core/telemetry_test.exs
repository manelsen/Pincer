defmodule Pincer.Core.TelemetryTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Telemetry

  setup do
    handler_id = "pincer-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:pincer, :error],
          [:pincer, :retry],
          [:pincer, :memory, :search],
          [:pincer, :memory, :recall]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  test "emit_error/2 publishes classified event" do
    Telemetry.emit_error(%Req.TransportError{reason: :timeout}, %{component: :llm_client})

    assert_receive {:telemetry, [:pincer, :error], %{count: 1}, metadata}
    assert metadata.class == :transport_timeout
    assert metadata.component == :llm_client
  end

  test "emit_retry/2 publishes retry event with wait measurement" do
    Telemetry.emit_retry({:http_error, 429, "rate"}, %{wait_ms: 42, action: :chat_completion})

    assert_receive {:telemetry, [:pincer, :retry], %{count: 1, wait_ms: 42}, metadata}
    assert metadata.class == :http_429
    assert metadata.action == :chat_completion
  end

  test "emit_memory_search/2 publishes search event with normalized measurements" do
    Telemetry.emit_memory_search(%{duration_ms: 12, hit_count: 3}, %{
      source: :messages,
      outcome: :ok,
      session_id: "s-1",
      query_length: 24
    })

    assert_receive {:telemetry, [:pincer, :memory, :search],
                    %{count: 1, duration_ms: 12, hit_count: 3}, metadata}

    assert metadata.source == :messages
    assert metadata.outcome == :ok
    assert metadata.session_id == "s-1"
    assert metadata.query_length == 24
  end

  test "emit_memory_recall/2 publishes aggregated recall event" do
    Telemetry.emit_memory_recall(
      %{
        duration_ms: 9,
        total_hits: 4,
        message_hits: 1,
        document_hits: 2,
        semantic_hits: 1,
        prompt_chars: 180,
        learnings_count: 2
      },
      %{eligible: true, session_id: "s-2", query_length: 31}
    )

    assert_receive {:telemetry, [:pincer, :memory, :recall],
                    %{
                      count: 1,
                      duration_ms: 9,
                      total_hits: 4,
                      message_hits: 1,
                      document_hits: 2,
                      semantic_hits: 1,
                      prompt_chars: 180,
                      learnings_count: 2
                    }, metadata}

    assert metadata.eligible == true
    assert metadata.session_id == "s-2"
    assert metadata.query_length == 31
  end
end
