defmodule Pincer.Channels.WhatsAppBridgeTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.WhatsApp.Bridge.Adapter

  describe "decode_events/2" do
    test "parses newline-delimited json events" do
      payload = ~s({"type":"ready"}\n{"type":"message","text":"oi"}\n)

      assert {events, ""} = Adapter.decode_events("", payload)

      assert events == [
               %{"type" => "ready"},
               %{"type" => "message", "text" => "oi"}
             ]
    end

    test "keeps incomplete line in buffer for next chunk" do
      assert {[], "{\"type\":\"ready\""} = Adapter.decode_events("", ~s({"type":"ready"))
      assert {[%{"type" => "ready"}], ""} = Adapter.decode_events(~s({"type":"ready"), "}\n")
    end

    test "drops malformed lines and keeps valid events" do
      payload = "not-json\n{\"type\":\"ready\"}\n"

      assert {[%{"type" => "ready"}], ""} = Adapter.decode_events("", payload)
    end
  end

  describe "to_port_env/1" do
    test "converts binary env pairs to charlists accepted by Port.open" do
      env =
        Adapter.to_port_env([
          {"WA_AUTH_DIR", "sessions/whatsapp"},
          {"WA_QR_ASCII", "true"},
          {"WA_QR_ASCII_SMALL", "true"},
          {"WA_PAIRING_PHONE", ""}
        ])

      assert env == [
               {~c"WA_AUTH_DIR", ~c"sessions/whatsapp"},
               {~c"WA_QR_ASCII", ~c"true"},
               {~c"WA_QR_ASCII_SMALL", ~c"true"}
             ]
    end
  end
end
