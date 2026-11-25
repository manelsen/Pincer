defmodule Pincer.Adapters.Tools.WebFetchError do
  @moduledoc """
  Pure formatter for `web_fetch` transport and TLS failures.
  """

  alias Pincer.Infra.Http

  @doc "Returns whether a transport failure reports a certificate hostname mismatch."
  @spec hostname_mismatch?(term()) :: boolean()
  def hostname_mismatch?(%Req.TransportError{reason: reason}),
    do: Http.transport_kind(reason) == :hostname_mismatch

  def hostname_mismatch?(_), do: false

  @doc "Formats a transport failure for the user."
  @spec format(term()) :: String.t()
  def format(%Req.TransportError{reason: reason} = error) do
    case Http.transport_kind(reason) do
      :hostname_mismatch -> "Fetch failed: TLS certificate does not match the requested host."
      :tls_handshake -> "Fetch failed: TLS handshake failed."
      :request_timeout -> "Fetch failed: request timed out."
      :connect_timeout -> "Fetch failed: connection timed out."
      :other -> "Fetch failed: #{inspect(error)}"
    end
  end

  def format(reason), do: "Fetch failed: #{inspect(reason)}"
end
