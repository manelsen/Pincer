defmodule Pincer.Channels.SharedTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Shared

  test "the package owns and exports its shared helpers" do
    assert [%{app: :pincer_shared, opts: opts}] =
             Shared.__info__(:attributes)[Boundary]

    assert opts[:deps] == [PincerPorts]

    assert opts[:exports] == [Inbound, SessionBridge, Text, TokenCache, WebhookVerifier]
  end
end
