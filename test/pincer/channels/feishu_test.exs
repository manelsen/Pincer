defmodule Pincer.Channels.FeishuTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Feishu

  @webhook_fixture %{
    "schema" => "2.0",
    "event" => %{
      "sender" => %{"sender_id" => %{"open_id" => "ou_test123"}},
      "message" => %{
        "chat_id" => "oc_test_chat",
        "message_id" => "om_test_msg",
        "message_type" => "text",
        "content" => Jason.encode!(%{"text" => "Hello from Feishu"})
      }
    }
  }

  describe "parse_webhook_event/1" do
    test "extracts all fields from a valid payload" do
      result = Feishu.parse_webhook_event(@webhook_fixture)

      assert result == %{
               open_id: "ou_test123",
               chat_id: "oc_test_chat",
               message_id: "om_test_msg",
               content: "Hello from Feishu",
               msg_type: "text"
             }
    end

    test "returns :error for malformed payload" do
      assert Feishu.parse_webhook_event(%{}) == :error
    end

    test "returns :error for nil" do
      assert Feishu.parse_webhook_event(nil) == :error
    end

    test "returns :error for payload missing event key" do
      assert Feishu.parse_webhook_event(%{"schema" => "2.0"}) == :error
    end

    test "returns raw content JSON when text key is absent" do
      payload =
        put_in(
          @webhook_fixture,
          ["event", "message", "content"],
          Jason.encode!(%{"image_key" => "img_123"})
        )

      result = Feishu.parse_webhook_event(payload)
      assert result.content == Jason.encode!(%{"image_key" => "img_123"})
    end
  end

  describe "format_session_id/1" do
    test "prefixes open_id with feishu_" do
      assert Feishu.format_session_id("ou_abc123") == "feishu_ou_abc123"
    end
  end

  describe "validate_webhook/4" do
    test "delegates to WebhookVerifier" do
      # Verify delegation by calling with values that should fail validation
      result = Feishu.validate_webhook("ts", "nonce", "body", "bad_sig")
      assert result == {:error, :invalid_signature}
    end
  end

  describe "start_link/1 (:ignore when env vars missing)" do
    test "returns :ignore when FEISHU_APP_ID is nil" do
      original_app_id = System.get_env("FEISHU_APP_ID")
      original_app_secret = System.get_env("FEISHU_APP_SECRET")

      System.delete_env("FEISHU_APP_ID")
      System.put_env("FEISHU_APP_SECRET", "secret")

      assert Feishu.start_link(%{}) == :ignore

      if original_app_id, do: System.put_env("FEISHU_APP_ID", original_app_id)
      if original_app_secret, do: System.put_env("FEISHU_APP_SECRET", original_app_secret)
    end

    test "returns :ignore when FEISHU_APP_SECRET is nil" do
      original_app_id = System.get_env("FEISHU_APP_ID")
      original_app_secret = System.get_env("FEISHU_APP_SECRET")

      System.put_env("FEISHU_APP_ID", "app_id")
      System.delete_env("FEISHU_APP_SECRET")

      assert Feishu.start_link(%{}) == :ignore

      if original_app_id, do: System.put_env("FEISHU_APP_ID", original_app_id)
      if original_app_secret, do: System.put_env("FEISHU_APP_SECRET", original_app_secret)
    end

    test "returns :ignore when both env vars are nil" do
      original_app_id = System.get_env("FEISHU_APP_ID")
      original_app_secret = System.get_env("FEISHU_APP_SECRET")

      System.delete_env("FEISHU_APP_ID")
      System.delete_env("FEISHU_APP_SECRET")

      assert Feishu.start_link(%{}) == :ignore

      if original_app_id, do: System.put_env("FEISHU_APP_ID", original_app_id)
      if original_app_secret, do: System.put_env("FEISHU_APP_SECRET", original_app_secret)
    end
  end
end
