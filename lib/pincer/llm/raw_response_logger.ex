defmodule Pincer.LLM.RawResponseLogger do
  @moduledoc """
  Centralized raw provider logging for LLM adapters.

  Keeps the logging format consistent so provider payload debugging does not
  depend on each adapter hand-rolling its own `inspect/2` behavior.
  """

  require Logger

  @doc """
  Logs a raw provider response body with status metadata.
  """
  @spec log_response(String.t(), non_neg_integer(), any()) :: :ok
  def log_response(provider, status, body) when is_binary(provider) do
    Logger.debug("[LLM RAW][#{provider}] status=#{status} body=#{inspect_raw(body)}")
    :ok
  end

  @doc """
  Logs a raw provider stream chunk or auxiliary payload.
  """
  @spec log_payload(String.t(), String.t(), any()) :: :ok
  def log_payload(provider, label, payload) when is_binary(provider) and is_binary(label) do
    Logger.debug("[LLM RAW][#{provider}][#{label}] #{inspect_raw(payload)}")
    :ok
  end

  defp inspect_raw(payload) do
    inspect(payload, pretty: true, limit: :infinity, printable_limit: :infinity)
  end
end
