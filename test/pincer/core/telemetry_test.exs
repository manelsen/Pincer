defmodule Pincer.Core.TelemetryTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Telemetry

  setup do
    handler_id = "pincer-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:pincer, :error], [:pincer, :retry]],
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
end
