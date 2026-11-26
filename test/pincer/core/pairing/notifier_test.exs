defmodule Pincer.Core.Pairing.NotifierTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Pincer.Core.Pairing.Notifier
  alias Pincer.Infra.PubSub

  describe "payload builders" do
    test "build_pairing_payload/5 formats metadata, ISO timestamp, and clamped TTL" do
      payload =
        Notifier.build_pairing_payload(:Telegram, " user-1 ", "123456", 61_000,
          issued_at_ms: 1_000,
          reused: true
        )

      assert payload == %{
               channel: "telegram",
               sender_id: "user-1",
               code: "123456",
               expires_at_ms: 61_000,
               expires_at_iso: "1970-01-01T00:01:01.000Z",
               ttl_seconds: 60,
               command: "/pair 123456",
               reused: true
             }

      clamped =
        Notifier.build_pairing_payload(:discord, "u2", "000000", 500, issued_at_ms: 1_000)

      assert clamped.ttl_seconds == 0
      assert clamped.reused == false
    end

    test "build_invite_payload/4 formats generic and targeted invite metadata" do
      targeted =
        Notifier.build_invite_payload(:telegram, "ANNIE42", 61_000,
          issued_at_ms: 1_000,
          agent_id: "  annie "
        )

      assert targeted == %{
               channel: "telegram",
               target_agent_id: "annie",
               code: "ANNIE42",
               expires_at_ms: 61_000,
               expires_at_iso: "1970-01-01T00:01:01.000Z",
               ttl_seconds: 60,
               command: "/pair ANNIE42",
               kind: :invite
             }

      generic =
        Notifier.build_invite_payload(:telegram, "GEN1", 61_000,
          issued_at_ms: 1_000,
          agent_id: "../invalid"
        )

      assert generic.target_agent_id == nil
      assert generic.kind == :invite
    end
  end

  describe "announce_pairing_code/5 and announce_invite_code/4" do
    test "logs warning and broadcasts pairing payload to session:cli:admin" do
      {:ok, _} = PubSub.subscribe("session:cli:admin")

      log =
        capture_log(fn ->
          assert :ok =
                   Notifier.announce_pairing_code(:telegram, "user-notify", "654321", 61_000,
                     issued_at_ms: 1_000,
                     reused: false
                   )
        end)

      assert log =~ "[PAIRING] issued channel=telegram sender=user-notify code=654321"
      assert log =~ "ttl_s=60 command=/pair 654321"

      assert_receive {:pairing_code,
                      %{
                        channel: "telegram",
                        sender_id: "user-notify",
                        code: "654321",
                        command: "/pair 654321",
                        reused: false
                      }}
    end

    test "logs invite warning and broadcasts invite payload to session:cli:admin" do
      {:ok, _} = PubSub.subscribe("session:cli:admin")

      log =
        capture_log(fn ->
          assert :ok =
                   Notifier.announce_invite_code(:discord, "INVITE1", 61_000,
                     issued_at_ms: 1_000,
                     agent_id: nil
                   )
        end)

      assert log =~ "[PAIRING] issued invite channel=discord target=<generic> code=INVITE1"

      assert_receive {:pairing_code,
                      %{
                        channel: "discord",
                        target_agent_id: nil,
                        code: "INVITE1",
                        kind: :invite
                      }}
    end
  end
end
