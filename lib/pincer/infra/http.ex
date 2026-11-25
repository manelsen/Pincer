defmodule Pincer.Infra.Http do
  @moduledoc "Classifies failures at the HTTP client boundary."

  @type transport_kind ::
          :request_timeout | :connect_timeout | :hostname_mismatch | :tls_handshake | :other

  @doc "Classifies a transport reason extracted at the HTTP adapter boundary."
  @spec transport_kind(term()) :: transport_kind()
  def transport_kind(:timeout), do: :request_timeout
  def transport_kind(:connect_timeout), do: :connect_timeout

  def transport_kind({:tls_alert, {:handshake_failure, details}}) do
    if details |> IO.iodata_to_binary() |> String.contains?("hostname_check_failed"),
      do: :hostname_mismatch,
      else: :tls_handshake
  rescue
    ArgumentError -> :tls_handshake
  end

  def transport_kind(_), do: :other
end
