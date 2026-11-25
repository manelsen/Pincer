defmodule Pincer.Infra.HttpTest do
  use ExUnit.Case, async: true

  alias Pincer.Infra.Http

  test "classifies HTTP transport failures by cause" do
    assert Http.transport_kind(:timeout) == :request_timeout
    assert Http.transport_kind(:connect_timeout) == :connect_timeout

    for {details, expected} <- [
          {["tls", ~c"hostname_check_failed"], :hostname_mismatch},
          {~c"other alert", :tls_handshake},
          {:unavailable, :tls_handshake}
        ] do
      reason = {:tls_alert, {:handshake_failure, details}}
      assert Http.transport_kind(reason) == expected
    end

    assert Http.transport_kind({:error, :timeout}) == :other
  end
end
