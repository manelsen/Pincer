defmodule Pincer.Adapters.Tools.GitHubError do
  @moduledoc """
  Pure formatter for GitHub API and transport failures.
  """

  @doc """
  Formats a non-2xx GitHub API response into a short user-facing message.
  """
  @spec format_http(non_neg_integer(), map() | term()) :: String.t()
  def format_http(401, _body), do: "GitHub authentication failed. Check token or scopes."

  def format_http(403, %{"message" => message}) when is_binary(message) do
    if String.contains?(String.downcase(message), "rate limit") do
      "GitHub rate limit exceeded. Retry later."
    else
      "GitHub access forbidden. Check token scopes or repository permissions."
    end
  end

  def format_http(404, _body), do: "GitHub resource not found or not accessible."

  def format_http(422, %{"message" => message}) when is_binary(message) do
    "GitHub rejected the request: #{message}"
  end

  def format_http(status, %{"message" => message}) when is_binary(message) do
    "GitHub API error #{status}: #{message}"
  end

  def format_http(status, _body), do: "GitHub API error #{status}"

  @doc """
  Formats a transport-layer failure into a short user-facing message.
  """
  @spec format_transport(term()) :: String.t()
  def format_transport(%Req.TransportError{reason: :timeout}), do: "GitHub request timed out."

  def format_transport(%Req.TransportError{reason: :connect_timeout}),
    do: "GitHub connection timed out."

  def format_transport(reason), do: "GitHub request failed: #{inspect(reason)}"
end
