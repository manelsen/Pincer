defmodule Pincer.Channels.Shared.WebhookVerifierTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Shared.WebhookVerifier

  describe "verify_feishu/4" do
    test "returns :ok for valid Feishu signature" do
      timestamp = "1609459200"
      nonce = "abc123"
      body = "{\"event\":\"message\"}"
      signature = "261bfc9631ec26be243306f38303f78417c8e59cf22f37759ddeefd3350637a3"

      assert :ok = WebhookVerifier.verify_feishu(timestamp, nonce, body, signature)
    end

    test "returns error for invalid Feishu signature" do
      timestamp = "1609459200"
      nonce = "abc123"
      body = "{\"event\":\"message\"}"

      assert {:error, :invalid_signature} =
               WebhookVerifier.verify_feishu(timestamp, nonce, body, "deadbeef")
    end
  end

  describe "verify_line/3" do
    test "returns :ok for valid LINE signature" do
      body = "{\"events\":[{\"type\":\"message\"}]}"
      channel_secret = "my_channel_secret_123"
      signature = "O1zaFhhvyw7G3GkPgIACAT/mThr2USNVjjPVtQSEPv8="

      assert :ok = WebhookVerifier.verify_line(body, channel_secret, signature)
    end

    test "returns error for invalid LINE signature" do
      body = "{\"events\":[{\"type\":\"message\"}]}"
      channel_secret = "my_channel_secret_123"

      assert {:error, :invalid_signature} =
               WebhookVerifier.verify_line(body, channel_secret, "invalidsig==")
    end
  end

  describe "verify_dingtalk/3" do
    test "returns :ok for valid DingTalk signature" do
      timestamp = "1609459200000"
      secret = "SECabcdef123456"
      signature = "n++bRoO4y8pG2bbKyOpWXDPxd84LESlRBmQpADmHZNU="

      assert :ok = WebhookVerifier.verify_dingtalk(timestamp, secret, signature)
    end

    test "returns error for invalid DingTalk signature" do
      timestamp = "1609459200000"
      secret = "SECabcdef123456"

      assert {:error, :invalid_signature} =
               WebhookVerifier.verify_dingtalk(timestamp, secret, "badsig==")
    end
  end
end
