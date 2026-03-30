defmodule Pincer.Channels.DingTalkTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.DingTalk

  @webhook_fixture %{
    "msgtype" => "text",
    "text" => %{"content" => "Hello from DingTalk"},
    "senderStaffId" => "user123",
    "conversationId" => "cid_test"
  }

  describe "parse_webhook_event/1" do
    test "extracts fields correctly from text webhook payload" do
      result = DingTalk.parse_webhook_event(@webhook_fixture)

      assert result.staff_id == "user123"
      assert result.conversation_id == "cid_test"
      assert result.text == "Hello from DingTalk"
      assert result.msg_type == "text"
    end

    test "falls back to senderId when senderStaffId is missing" do
      payload = %{
        "msgtype" => "text",
        "text" => %{"content" => "Hello"},
        "senderId" => "fallback_user",
        "conversationId" => "cid_456"
      }

      result = DingTalk.parse_webhook_event(payload)
      assert result.staff_id == "fallback_user"
    end

    test "falls back to messageType when msgtype is missing" do
      payload = %{
        "messageType" => "richText",
        "text" => %{"content" => "Rich"},
        "senderStaffId" => "u1",
        "conversationId" => "cid_789"
      }

      result = DingTalk.parse_webhook_event(payload)
      assert result.msg_type == "richText"
    end

    test "returns :error for malformed payload missing conversationId" do
      assert DingTalk.parse_webhook_event(%{"msgtype" => "text"}) == :error
    end

    test "returns :error for non-map payload" do
      assert DingTalk.parse_webhook_event(nil) == :error
      assert DingTalk.parse_webhook_event("string") == :error
    end

    test "returns :error when senderStaffId and senderId are both missing" do
      payload = %{
        "msgtype" => "text",
        "text" => %{"content" => "Hello"},
        "conversationId" => "cid_test"
      }

      assert DingTalk.parse_webhook_event(payload) == :error
    end
  end

  describe "format_session_id/1" do
    test "returns dingtalk_ prefixed session ID" do
      assert DingTalk.format_session_id("user123") == "dingtalk_user123"
    end

    test "handles empty string" do
      assert DingTalk.format_session_id("") == "dingtalk_"
    end
  end

  describe "start_link/1" do
    test "returns :ignore when DINGTALK_CLIENT_ID is nil" do
      original_id = System.get_env("DINGTALK_CLIENT_ID")
      original_secret = System.get_env("DINGTALK_CLIENT_SECRET")
      System.delete_env("DINGTALK_CLIENT_ID")

      on_exit(fn ->
        if original_id,
          do: System.put_env("DINGTALK_CLIENT_ID", original_id),
          else: System.delete_env("DINGTALK_CLIENT_ID")

        if original_secret,
          do: System.put_env("DINGTALK_CLIENT_SECRET", original_secret),
          else: System.delete_env("DINGTALK_CLIENT_SECRET")
      end)

      assert DingTalk.start_link(%{}) == :ignore
    end

    test "returns :ignore when DINGTALK_CLIENT_SECRET is nil" do
      original_id = System.get_env("DINGTALK_CLIENT_ID")
      original_secret = System.get_env("DINGTALK_CLIENT_SECRET")
      System.delete_env("DINGTALK_CLIENT_SECRET")

      on_exit(fn ->
        if original_id,
          do: System.put_env("DINGTALK_CLIENT_ID", original_id),
          else: System.delete_env("DINGTALK_CLIENT_ID")

        if original_secret,
          do: System.put_env("DINGTALK_CLIENT_SECRET", original_secret),
          else: System.delete_env("DINGTALK_CLIENT_SECRET")
      end)

      assert DingTalk.start_link(%{}) == :ignore
    end
  end

  describe "handles_session?/1" do
    test "matches dingtalk_ prefixed session IDs" do
      assert DingTalk.handles_session?("dingtalk_user123") == true
    end

    test "rejects non-dingtalk session IDs" do
      assert DingTalk.handles_session?("line_U1234567890") == false
      assert DingTalk.handles_session?("telegram_123") == false
    end
  end

  describe "resolve_recipient/1" do
    test "extracts staff_id from dingtalk_ session ID" do
      assert DingTalk.resolve_recipient("dingtalk_user123") == "user123"
    end

    test "returns session ID unchanged if no prefix match" do
      assert DingTalk.resolve_recipient("something_else") == "something_else"
    end
  end
end
