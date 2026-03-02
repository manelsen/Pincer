defmodule Pincer.Core.Telemetry do
  @moduledoc """
  Thin wrapper around `:telemetry` with Pincer-specific events.
  """

  alias Pincer.Core.ErrorClass

  @error_event [:pincer, :error]
  @retry_event [:pincer, :retry]

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

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(metadata) when is_list(metadata), do: Map.new(metadata)
  defp normalize_metadata(_), do: %{}

  defp parse_wait_ms(ms) when is_integer(ms) and ms >= 0, do: ms
  defp parse_wait_ms(_), do: 0
end
