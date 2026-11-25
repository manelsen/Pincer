defmodule Pincer.Channels.OutboundMessagingTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.OutboundMessaging

  test "returns a transport error for an unknown channel" do
    assert {:error, {:unsupported_channel, :unknown}} =
             OutboundMessaging.send_message(:unknown, "recipient", "message", [])
  end

  test "reports that WhatsApp does not support file uploads through this adapter" do
    file = %{name: "document.txt", path: "/unused/document.txt", body: "document"}

    assert {:error, "File sending is not supported on WhatsApp (file: document.txt)."} =
             OutboundMessaging.send_file(:whatsapp, "recipient", file, "")
  end
end
