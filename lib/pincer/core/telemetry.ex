defmodule Pincer.Core.Telemetry do
  @moduledoc """
  Thin wrapper around `:telemetry` with Pincer-specific events.
  """

  alias Pincer.Core.ErrorClass

  @error_event [:pincer, :error]
  @retry_event [:pincer, :retry]
  @memory_search_event [:pincer, :memory, :search]
  @memory_recall_event [:pincer, :memory, :recall]
  @conversation_start_event [:pincer, :conversation, :session, :start]
  @conversation_stop_event [:pincer, :conversation, :session, :stop]
  @conversation_turn_start_event [:pincer, :conversation, :turn, :start]
  @conversation_turn_stop_event [:pincer, :conversation, :turn, :stop]
  @conversation_error_event [:pincer, :conversation, :turn, :error]

  @spec emit_error(term(), map() | keyword()) :: :ok
  def emit_error(reason, metadata \\ %{}) do
    metadata =
      metadata
      |> normalize_metadata()
      |> Map.put_new(:class, ErrorClass.classify(reason))

    :telemetry.execute(@error_event, %{count: 1}, metadata)
    :ok
  end

  @spec emit_retry(term(), map() | keyword()) :: :ok
  def emit_retry(reason, metadata \\ %{}) do
    metadata = normalize_metadata(metadata)
    wait_ms = parse_wait_ms(Map.get(metadata, :wait_ms, 0))

    metadata =
      metadata
      |> Map.put(:wait_ms, wait_ms)
      |> Map.put_new(:class, ErrorClass.classify(reason))

    :telemetry.execute(@retry_event, %{count: 1, wait_ms: wait_ms}, metadata)
    :ok
  end

  @doc """
  Emits a per-source memory search event.
  """
  @spec emit_memory_search(map() | keyword(), map() | keyword()) :: :ok
  def emit_memory_search(measurements, metadata \\ %{}) do
    measurements = normalize_memory_search_measurements(measurements)
    metadata = normalize_metadata(metadata)

    :telemetry.execute(@memory_search_event, measurements, metadata)
    :ok
  end

  @doc """
  Emits an aggregated memory recall event for one recall build.
  """
  @spec emit_memory_recall(map() | keyword(), map() | keyword()) :: :ok
  def emit_memory_recall(measurements, metadata \\ %{}) do
    measurements = normalize_memory_recall_measurements(measurements)
    metadata = normalize_metadata(metadata)

    :telemetry.execute(@memory_recall_event, measurements, metadata)
    :ok
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(metadata) when is_list(metadata), do: Map.new(metadata)
  defp normalize_metadata(_), do: %{}

  defp normalize_memory_search_measurements(measurements) do
    measurements = normalize_metadata(measurements)

    %{
      count: 1,
      duration_ms: parse_non_negative(Map.get(measurements, :duration_ms, 0)),
      hit_count: parse_non_negative(Map.get(measurements, :hit_count, 0))
    }
  end

  defp normalize_memory_recall_measurements(measurements) do
    measurements = normalize_metadata(measurements)

    %{
      count: 1,
      duration_ms: parse_non_negative(Map.get(measurements, :duration_ms, 0)),
      total_hits: parse_non_negative(Map.get(measurements, :total_hits, 0)),
      message_hits: parse_non_negative(Map.get(measurements, :message_hits, 0)),
      document_hits: parse_non_negative(Map.get(measurements, :document_hits, 0)),
      semantic_hits: parse_non_negative(Map.get(measurements, :semantic_hits, 0)),
      prompt_chars: parse_non_negative(Map.get(measurements, :prompt_chars, 0)),
      learnings_count: parse_non_negative(Map.get(measurements, :learnings_count, 0))
    }
  end

  @doc "Emits a conversation session start event."
  @spec emit_conversation_start(String.t(), map()) :: :ok
  def emit_conversation_start(session_id, metadata \\ %{}) when is_binary(session_id) do
    :telemetry.execute(
      @conversation_start_event,
      %{count: 1},
      Map.merge(normalize_metadata(metadata), %{session_id: session_id})
    )

    :ok
  end

  @doc "Emits a conversation session stop event."
  @spec emit_conversation_stop(String.t(), map()) :: :ok
  def emit_conversation_stop(session_id, metadata \\ %{}) when is_binary(session_id) do
    :telemetry.execute(
      @conversation_stop_event,
      %{count: 1},
      Map.merge(normalize_metadata(metadata), %{session_id: session_id})
    )

    :ok
  end

  @doc "Emits a conversation turn start event and returns monotonic start time."
  @spec emit_conversation_turn_start(String.t(), map()) :: integer()
  def emit_conversation_turn_start(session_id, metadata \\ %{}) when is_binary(session_id) do
    start_ms = System.monotonic_time(:millisecond)

    :telemetry.execute(
      @conversation_turn_start_event,
      %{count: 1},
      Map.merge(normalize_metadata(metadata), %{session_id: session_id})
    )

    start_ms
  end

  @doc """
  Emits a conversation turn stop event with duration, token counts, and tool_calls.
  `start_ms` should be the value returned by `emit_conversation_turn_start/2`.
  """
  @spec emit_conversation_turn_stop(String.t(), integer(), map()) :: :ok
  def emit_conversation_turn_stop(session_id, start_ms, metadata \\ %{})
      when is_binary(session_id) and is_integer(start_ms) do
    duration_ms = System.monotonic_time(:millisecond) - start_ms
    meta = normalize_metadata(metadata)

    measurements = %{
      count: 1,
      duration_ms: max(0, duration_ms),
      prompt_tokens: parse_non_negative(Map.get(meta, :prompt_tokens, 0)),
      completion_tokens: parse_non_negative(Map.get(meta, :completion_tokens, 0)),
      tool_calls: parse_non_negative(Map.get(meta, :tool_calls, 0))
    }

    :telemetry.execute(
      @conversation_turn_stop_event,
      measurements,
      Map.merge(meta, %{session_id: session_id})
    )

    :ok
  end

  @doc "Emits a conversation turn error event."
  @spec emit_conversation_error(String.t(), term(), map()) :: :ok
  def emit_conversation_error(session_id, reason, metadata \\ %{}) when is_binary(session_id) do
    meta = normalize_metadata(metadata)

    :telemetry.execute(
      @conversation_error_event,
      %{count: 1},
      Map.merge(meta, %{session_id: session_id, reason: inspect(reason)})
    )

    :ok
  end

  defp parse_wait_ms(ms) when is_integer(ms) and ms >= 0, do: ms
  defp parse_wait_ms(_), do: 0

  defp parse_non_negative(value) when is_integer(value) and value >= 0, do: value
  defp parse_non_negative(_), do: 0
end
