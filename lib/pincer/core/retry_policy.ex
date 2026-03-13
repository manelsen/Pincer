defmodule Pincer.Core.RetryPolicy do
  @moduledoc """
  Central retry/transient policy shared by core and adapters.

  This module keeps retryability and transient classification in one place so
  channel/session/LLM flows do not maintain divergent error lists.
  """

  alias Pincer.Core.ErrorClass

  @transient_transport_reasons [
    :timeout,
    :connect_timeout,
    :econnrefused,
    :closed,
    :enetunreach,
    :ehostunreach
  ]

  @retryable_http_statuses [408, 429, 500, 502, 503, 504]
  @transient_classes [
    :http_408,
    :http_429,
    :http_5xx,
    :transport_timeout,
    :transport_connect,
    :transport_dns,
    :process_timeout,
    :retry_timeout,
    :stream_payload
  ]

  @fail_fast_classes [
    :missing_credentials,
    :auth_cooling_down,
    :tool_calling_unsupported,
    :context_overflow,
    :provider_payload,
    :provider_non_json,
    :provider_empty,
    :http_401,
    :http_403,
    :http_404
  ]

  @doc """
  Returns `true` when the reason should be retried by request-level logic.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(reason)

  def retryable?({:http_error, status, _}) when is_integer(status),
    do: status in @retryable_http_statuses

  def retryable?({:http_error, status, _, _}) when is_integer(status),
    do: status in @retryable_http_statuses

  def retryable?(%Req.TransportError{reason: reason}),
    do: reason in @transient_transport_reasons

  def retryable?({:timeout, _}), do: true
  def retryable?(_), do: false

  @doc """
  Returns `true` when the reason should stop immediately without retry/failover noise.
  """
  @spec fail_fast?(term()) :: boolean()
  def fail_fast?(reason), do: ErrorClass.classify(reason) in @fail_fast_classes

  @doc """
  Returns `true` when the reason should be treated as transient in logging/ops.
  """
  @spec transient?(term()) :: boolean()
  def transient?(reason), do: ErrorClass.classify(reason) in @transient_classes

  @doc """
  Reads and normalizes `Retry-After` metadata (for 429/503), clamped by deadline.
  """
  @spec retry_after_ms(term(), non_neg_integer(), pos_integer()) :: non_neg_integer() | nil
  def retry_after_ms(reason, elapsed_ms, max_elapsed_ms)
      when is_integer(elapsed_ms) and elapsed_ms >= 0 and is_integer(max_elapsed_ms) and
             max_elapsed_ms > 0 do
    with {:http_error, status, _body, meta} <- reason,
         true <- status in [429, 503],
         true <- is_map(meta),
         value when not is_nil(value) <- retry_after_value(meta),
         ms when is_integer(ms) and ms > 0 <- parse_retry_after(value) do
      min(ms, max(0, max_elapsed_ms - elapsed_ms))
    else
      _ -> nil
    end
  end

  def retry_after_ms(_reason, _elapsed_ms, _max_elapsed_ms), do: nil

  @doc """
  Parses `Retry-After` as milliseconds.

  Accepts:
  - integer milliseconds
  - string seconds (`"2"`)
  - HTTP-date (`"Tue, 14 Nov 2023 22:13:21 GMT"`)
  """
  @spec parse_retry_after(term(), integer()) :: non_neg_integer() | nil
  def parse_retry_after(value, now_ms \\ System.system_time(:millisecond))

  def parse_retry_after(value, _now_ms) when is_integer(value) and value >= 0, do: value

  def parse_retry_after(value, now_ms) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        seconds * 1000

      _ ->
        parse_http_date_ms(value, now_ms)
    end
  end

  def parse_retry_after(_value, _now_ms), do: nil

  defp retry_after_value(meta) do
    Map.get(meta, :retry_after_ms) ||
      Map.get(meta, "retry_after_ms") ||
      Map.get(meta, :retry_after) ||
      Map.get(meta, "retry_after")
  end

  defp parse_http_date_ms(http_date, now_ms) do
    with %{
           "day" => day_s,
           "month" => month_s,
           "year" => year_s,
           "hour" => hour_s,
           "minute" => minute_s,
           "second" => second_s
         } <-
           Regex.named_captures(
             ~r/^[A-Za-z]{3}, (?<day>\d{2}) (?<month>[A-Za-z]{3}) (?<year>\d{4}) (?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2}) GMT$/,
             http_date
           ),
         month when is_integer(month) <- month_number(month_s),
         {day, ""} <- Integer.parse(day_s),
         {year, ""} <- Integer.parse(year_s),
         {hour, ""} <- Integer.parse(hour_s),
         {minute, ""} <- Integer.parse(minute_s),
         {second, ""} <- Integer.parse(second_s),
         {:ok, naive_dt} <- NaiveDateTime.new(year, month, day, hour, minute, second) do
      target_ms =
        naive_dt
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.to_unix(:millisecond)

      max(0, target_ms - now_ms)
    else
      _ -> nil
    end
  end

  defp month_number("Jan"), do: 1
  defp month_number("Feb"), do: 2
  defp month_number("Mar"), do: 3
  defp month_number("Apr"), do: 4
  defp month_number("May"), do: 5
  defp month_number("Jun"), do: 6
  defp month_number("Jul"), do: 7
  defp month_number("Aug"), do: 8
  defp month_number("Sep"), do: 9
  defp month_number("Oct"), do: 10
  defp month_number("Nov"), do: 11
  defp month_number("Dec"), do: 12
  defp month_number(_), do: nil
end
