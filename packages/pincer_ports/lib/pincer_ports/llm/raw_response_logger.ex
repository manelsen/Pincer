defmodule PincerPorts.LLM.RawResponseLogger do
  @moduledoc """
  Centralized raw provider logging for LLM adapters.

  Raw payload logging is disabled by default (`:log_raw_llm_payloads` or
  `PINCER_LOG_RAW_LLM=true`) so provider responses are not duplicated into logs
  unintentionally. When enabled, sensitive fields are redacted and output is
  strictly bounded.
  """

  require Logger

  @max_output_bytes 4_096
  @max_inspect_depth 16

  @sensitive_keys MapSet.new([
                    "api_key",
                    "apikey",
                    "token",
                    "access_token",
                    "refresh_token",
                    "id_token",
                    "secret",
                    "client_secret",
                    "password",
                    "passwd",
                    "authorization",
                    "proxy_authorization",
                    "x-api-key",
                    "x_api_key",
                    "private_key",
                    "cookie",
                    "set-cookie"
                  ])

  @doc """
  Logs a bounded, redacted provider response body at `:debug` when opt-in logging is enabled.
  """
  @spec log_response(String.t(), non_neg_integer(), any()) :: :ok
  def log_response(provider, status, body) when is_binary(provider) do
    if enabled?() do
      Logger.debug("[LLM RAW][#{provider}] status=#{status} body=#{format_raw(body)}")
    end

    :ok
  end

  @doc """
  Logs a bounded, redacted stream chunk or auxiliary payload at `:debug` when opt-in logging is enabled.
  """
  @spec log_payload(String.t(), String.t(), any()) :: :ok
  def log_payload(provider, label, payload) when is_binary(provider) and is_binary(label) do
    if enabled?() do
      Logger.debug("[LLM RAW][#{provider}][#{label}] #{format_raw(payload)}")
    end

    :ok
  end

  defp enabled? do
    Application.get_env(:pincer, :log_raw_llm_payloads, false) == true or
      System.get_env("PINCER_LOG_RAW_LLM") in ["1", "true", "TRUE", "yes", "YES"]
  end

  defp format_raw(payload) do
    formatted =
      payload
      |> redact_payload(0)
      |> inspect(pretty: false, limit: 50, printable_limit: 2_048)

    truncate_bytes(formatted, @max_output_bytes)
  end

  defp redact_payload(_payload, depth) when depth > @max_inspect_depth, do: "[...]"

  defp redact_payload(%_struct{} = struct, _depth), do: struct

  defp redact_payload(map, depth) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact_payload(value, depth + 1)}
      end
    end)
  end

  defp redact_payload(list, depth) when is_list(list) do
    if Keyword.keyword?(list) do
      Enum.map(list, fn {key, value} ->
        if sensitive_key?(key) do
          {key, "[REDACTED]"}
        else
          {key, redact_payload(value, depth + 1)}
        end
      end)
    else
      Enum.map(list, &redact_payload(&1, depth + 1))
    end
  end

  defp redact_payload(binary, _depth) when is_binary(binary) do
    redact_binary(binary)
  end

  defp redact_payload(other, _depth), do: other

  defp sensitive_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.trim()
      |> String.downcase()

    MapSet.member?(@sensitive_keys, normalized) or
      String.ends_with?(normalized, "_key") or
      String.ends_with?(normalized, "_token") or
      String.ends_with?(normalized, "_secret")
  end

  defp redact_binary(text) do
    text
    |> String.replace(~r/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i, "Bearer [REDACTED]")
    |> String.replace(
      ~r/"([^"]*(?:api_?key|token|secret|password|authorization)[^"]*)"\s*:\s*"[^"]*"/i,
      ~S("\1":"[REDACTED]")
    )
  end

  defp truncate_bytes(str, max_bytes) when byte_size(str) <= max_bytes, do: str

  defp truncate_bytes(str, max_bytes) do
    String.slice(str, 0, max_bytes) <> "...[truncated]"
  end
end
