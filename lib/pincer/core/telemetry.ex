defmodule Pincer.Core.Telemetry do
  @moduledoc """
  Thin wrapper around `:telemetry` with Pincer-specific events.
  """

  alias Pincer.Core.ErrorClass

  @error_event [:pincer, :error]
  @retry_event [:pincer, :retry]
  @memory_search_event [:pincer, :memory, :search]
  @memory_recall_event [:pincer, :memory, :recall]

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

  defp parse_wait_ms(ms) when is_integer(ms) and ms >= 0, do: ms
  defp parse_wait_ms(_), do: 0

  defp parse_non_negative(value) when is_integer(value) and value >= 0, do: value
  defp parse_non_negative(_), do: 0
end
