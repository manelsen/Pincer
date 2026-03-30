defmodule Pincer.Channels.LineTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Line

  @webhook_fixture %{
    "events" => [
      %{
        "type" => "message",
        "replyToken" => "test_reply_token",
        "source" => %{"userId" => "U1234567890", "type" => "user"},
        "message" => %{"type" => "text", "text" => "Hello bot"}
      }
    ]
  }

  describe "parse_webhook_events/1" do
    test "extracts text message events from webhook payload" do
      [event] = Line.parse_webhook_events(@webhook_fixture)

      assert event.user_id == "U1234567890"
      assert event.text == "Hello bot"
      assert event.reply_token == "test_reply_token"
    end

    test "returns empty list for empty events array" do
      assert Line.parse_webhook_events(%{"events" => []}) == []
    end

    test "ignores non-text message events" do
      payload = %{
        "events" => [
          %{
            "type" => "message",
            "replyToken" => "rt_image",
            "source" => %{"userId" => "U111", "type" => "user"},
            "message" => %{"type" => "image", "id" => "img_1"}
          }
        ]
      }

      assert Line.parse_webhook_events(payload) == []
    end

    test "ignores non-message events" do
      payload = %{
        "events" => [
          %{
            "type" => "follow",
            "replyToken" => "rt_follow",
            "source" => %{"userId" => "U222", "type" => "user"}
          }
        ]
      }

      assert Line.parse_webhook_events(payload) == []
    end

    test "handles multiple text events" do
      payload = %{
        "events" => [
          %{
            "type" => "message",
            "replyToken" => "rt1",
            "source" => %{"userId" => "U111", "type" => "user"},
            "message" => %{"type" => "text", "text" => "First"}
          },
          %{
            "type" => "message",
            "replyToken" => "rt2",
            "source" => %{"userId" => "U222", "type" => "user"},
            "message" => %{"type" => "text", "text" => "Second"}
          }
        ]
      }

      events = Line.parse_webhook_events(payload)
      assert length(events) == 2
      assert Enum.at(events, 0).user_id == "U111"
      assert Enum.at(events, 1).user_id == "U222"
    end
  end

  describe "session_id/1" do
    test "formats session ID as line_ prefix with userId" do
      assert Line.session_id("U1234567890") == "line_U1234567890"
    end
  end

  describe "start_link/1" do
    test "returns :ignore when LINE_CHANNEL_ACCESS_TOKEN is nil" do
      original = System.get_env("LINE_CHANNEL_ACCESS_TOKEN")
      System.delete_env("LINE_CHANNEL_ACCESS_TOKEN")

      on_exit(fn ->
        if original do
          System.put_env("LINE_CHANNEL_ACCESS_TOKEN", original)
        else
          System.delete_env("LINE_CHANNEL_ACCESS_TOKEN")
        end
      end)

      assert Line.start_link(%{}) == :ignore
    end
  end

  describe "handles_session?/1" do
    test "matches line_ prefixed session IDs" do
      assert Line.handles_session?("line_U1234567890") == true
    end

    test "rejects non-line session IDs" do
      assert Line.handles_session?("telegram_123") == false
    end
  end

  describe "resolve_recipient/1" do
    test "extracts userId from line_ session ID" do
      assert Line.resolve_recipient("line_U1234567890") == "U1234567890"
    end

    test "returns session ID unchanged if no prefix" do
      assert Line.resolve_recipient("something_else") == "something_else"
    end
  end
end
