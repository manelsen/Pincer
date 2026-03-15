defmodule Pincer.Adapters.Tools.WebFetchError do
  @moduledoc """
  Pure formatter for `web_fetch` transport and TLS failures.
  """

  @doc """
  Formats a low-level fetch error into a short, user-facing message.
  """
  @spec hostname_mismatch?(term()) :: boolean()
  def hostname_mismatch?(%Req.TransportError{reason: {:tls_alert, {:handshake_failure, details}}}) do
    details
    |> IO.iodata_to_binary()
    |> String.contains?("hostname_check_failed")
  end

  def hostname_mismatch?(_reason), do: false

  @spec format(term()) :: String.t()
  def format(%Req.TransportError{reason: {:tls_alert, {:handshake_failure, details}}}) do
    if hostname_mismatch?(%Req.TransportError{
         reason: {:tls_alert, {:handshake_failure, details}}
       }) do
      "Fetch failed: TLS certificate does not match the requested host."
    else
      "Fetch failed: TLS handshake failed."
    end
  end

  def format(%Req.TransportError{reason: :timeout}), do: "Fetch failed: request timed out."

  def format(%Req.TransportError{reason: :connect_timeout}),
    do: "Fetch failed: connection timed out."

  def format(reason), do: "Fetch failed: #{inspect(reason)}"
end
