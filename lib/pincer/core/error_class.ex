defmodule Pincer.Core.ErrorClass do
  @moduledoc """
  Stable classification for operational errors.

  Classes are intentionally coarse-grained so telemetry dashboards and alerting
  remain stable even when low-level error formats vary by adapter/provider.
  """

  @spec classify(term()) :: atom()
  def classify(reason), do: reason |> normalize() |> classify_normalized()

  defp normalize({:error, reason}), do: normalize(reason)
  defp normalize({:EXIT, reason}), do: normalize(reason)
  defp normalize({:shutdown, reason}), do: normalize(reason)
  defp normalize(reason), do: reason

  defp classify_normalized({:provider_error, code, msg}),
    do: classify_normalized({:http_error, normalize_provider_code(code), msg})

  defp classify_normalized({:missing_credentials, _env_key}), do: :missing_credentials
  defp classify_normalized(:missing_credentials), do: :missing_credentials
  defp classify_normalized(:all_profiles_cooling_down), do: :auth_cooling_down

  defp classify_normalized({:http_error, status, msg, _meta}),
    do: classify_normalized({:http_error, status, msg})

  defp classify_normalized({:http_error, 400, msg}) when is_binary(msg) do
    cond do
      tool_calling_unsupported_message?(msg) -> :tool_calling_unsupported
      context_overflow_message?(msg) -> :context_overflow
      provider_error_message?(msg) -> :provider_payload
      true -> :http_400
    end
  end

  defp classify_normalized({:http_error, 401, _}), do: :http_401
  defp classify_normalized({:http_error, 403, _}), do: :http_403
  defp classify_normalized({:http_error, 404, _}), do: :http_404
  defp classify_normalized({:http_error, 408, _}), do: :http_408

  defp classify_normalized({:http_error, 429, msg}) when is_binary(msg) do
    if quota_exhausted_message?(msg), do: :quota_exhausted, else: :http_429
  end

  defp classify_normalized({:http_error, 429, _}), do: :http_429

  defp classify_normalized({:http_error, status, _}) when is_integer(status) and status >= 500,
    do: :http_5xx

  defp classify_normalized(%Req.TransportError{reason: :timeout}), do: :transport_timeout
  defp classify_normalized(%Req.TransportError{reason: :connect_timeout}), do: :transport_timeout
  defp classify_normalized(%Req.TransportError{reason: :econnrefused}), do: :transport_connect
  defp classify_normalized(%Req.TransportError{reason: :closed}), do: :transport_connect
  defp classify_normalized(%Req.TransportError{reason: :enetunreach}), do: :transport_connect
  defp classify_normalized(%Req.TransportError{reason: :ehostunreach}), do: :transport_connect
  defp classify_normalized(%Req.TransportError{reason: :nxdomain}), do: :transport_dns
  defp classify_normalized(%Req.TransportError{}), do: :transport_other

  defp classify_normalized({:timeout, _}), do: :process_timeout
  defp classify_normalized({:retry_timeout, _}), do: :retry_timeout
  defp classify_normalized(:tool_loop), do: :tool_loop

  defp classify_normalized(%Postgrex.Error{postgres: %{code: :undefined_table}}), do: :db_schema

  defp classify_normalized(%Postgrex.Error{} = error) do
    if db_schema_message?(Exception.message(error)), do: :db_schema, else: :db
  end

  defp classify_normalized(%RuntimeError{message: msg}) when is_binary(msg) do
    if db_schema_message?(msg), do: :db_schema, else: :internal
  end

  defp classify_normalized(%Protocol.UndefinedError{protocol: protocol})
       when protocol in [Enumerable, Collectable],
       do: :stream_payload

  defp classify_normalized({:invalid_stream_response, _}), do: :stream_payload
  defp classify_normalized(:unexpected_response_format), do: :provider_payload
  defp classify_normalized(:non_json_response), do: :provider_non_json
  defp classify_normalized(:empty_response), do: :provider_empty
  defp classify_normalized({:invalid_chat_response, _}), do: :internal

  defp classify_normalized(reason) when is_exception(reason), do: :internal

  defp classify_normalized(_), do: :unknown

  defp normalize_provider_code(code) when is_integer(code), do: code
  defp normalize_provider_code(_), do: 400

  defp context_overflow_message?(msg) do
    down = String.downcase(msg)

    String.contains?(down, "maximum context length") or
      String.contains?(down, "input tokens") or
      String.contains?(down, "max_tokens") or
      String.contains?(down, "max_completion_tokens")
  end

  defp tool_calling_unsupported_message?(msg) do
    down = String.downcase(msg)

    String.contains?(down, "tool calling") and
      (String.contains?(down, "not supported") or String.contains?(down, "unsupported"))
  end

  defp quota_exhausted_message?(msg) do
    down = String.downcase(msg)
    String.contains?(down, "insufficient_quota") or String.contains?(msg, "余额不足")
  end

  defp provider_error_message?(msg) do
    down = String.downcase(msg)
    String.contains?(down, "provider returned error")
  end

  defp db_schema_message?(msg) when is_binary(msg) do
    down = String.downcase(msg)

    (String.contains?(down, "no such table") or
       String.contains?(down, "undefined table") or
       String.contains?(down, "does not exist")) and
      (String.contains?(down, "table") or String.contains?(down, "relation"))
  end
end
