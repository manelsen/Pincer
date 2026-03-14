defmodule Pincer.Adapters.Tools.WebFetchErrorTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.WebFetchError

  test "formats TLS hostname mismatch tersely" do
    error =
      %Req.TransportError{
        reason:
          {:tls_alert,
           {:handshake_failure,
            ~c"TLS client alert {bad_cert,{hostname_check_failed,{requested,\"www.cade.com.br\"}}}"}}
      }

    assert WebFetchError.format(error) ==
             "Fetch failed: TLS certificate does not match the requested host."
  end

  test "formats transport timeouts tersely" do
    assert WebFetchError.format(%Req.TransportError{reason: :timeout}) ==
             "Fetch failed: request timed out."

    assert WebFetchError.format(%Req.TransportError{reason: :connect_timeout}) ==
             "Fetch failed: connection timed out."
  end

  test "falls back to inspect for unknown errors" do
    assert WebFetchError.format(:econnrefused) == "Fetch failed: :econnrefused"
  end
end
