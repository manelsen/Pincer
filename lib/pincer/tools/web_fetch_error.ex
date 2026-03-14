defmodule Pincer.Adapters.Tools.WebFetchError do
  @moduledoc """
  Pure formatter for `web_fetch` transport and TLS failures.
  """

  @doc """
  Formats a low-level fetch error into a short, user-facing message.
  """
  @spec format(term()) :: String.t()
  def format(%Req.TransportError{reason: {:tls_alert, {:handshake_failure, details}}}) do
    details_text = IO.iodata_to_binary(details)

    if String.contains?(details_text, "hostname_check_failed") do
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
