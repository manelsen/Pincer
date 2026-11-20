defmodule Pincer.Channels.WhatsAppBridgeTest do
  use ExUnit.Case, async: true

  # pincer_whatsapp is compiled only when PINCER_WHATSAPP=1 (see mix.exs).
  if Code.ensure_loaded?(Pincer.Channels.WhatsApp.Bridge.Adapter) do
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

    describe "Mix.Tasks.Compile.WhatsappBridge" do
      test "expands binary output path inside package priv/ instead of Go source directory" do
        package_root = Path.expand("../../../packages/pincer_whatsapp", __DIR__)
        expected = Path.join(package_root, "priv/whatsapp_bridge")

        assert Mix.Tasks.Compile.WhatsappBridge.output_binary_path(package_root) == expected
        refute String.contains?(expected, "priv/src/whatsapp_bridge/priv")
      end

      test "needs_rebuild?/2 handles existing binary mtime without crashing and rebuilds only when outdated" do
        tmp =
          Path.join(System.tmp_dir!(), "pincer_wa_rebuild_#{System.unique_integer([:positive])}")

        src_dir = Path.join(tmp, "src")
        bin_path = Path.join(tmp, "priv/whatsapp_bridge")
        File.mkdir_p!(src_dir)
        File.mkdir_p!(Path.dirname(bin_path))

        go_file = Path.join(src_dir, "main.go")
        File.write!(go_file, "package main\n")

        # Binary missing -> rebuild needed
        assert Mix.Tasks.Compile.WhatsappBridge.needs_rebuild?(bin_path, src_dir)

        File.write!(bin_path, "binary")
        File.touch!(go_file, 1_700_000_000)
        File.touch!(bin_path, 1_700_000_100)
        refute Mix.Tasks.Compile.WhatsappBridge.needs_rebuild?(bin_path, src_dir)

        File.touch!(go_file, 1_700_000_200)
        assert Mix.Tasks.Compile.WhatsappBridge.needs_rebuild?(bin_path, src_dir)

        File.rm_rf!(tmp)
      end
    end
  end
end
