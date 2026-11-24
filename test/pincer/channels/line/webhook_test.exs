defmodule Pincer.Channels.Line.WebhookTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Pincer.Channels.Line.Webhook

  @secret "line-test-secret"

  setup do
    original_config = Application.get_env(:pincer, :line_channel_config)
    original_secret = System.get_env("PINCER_TEST_LINE_SECRET")
    original_dispatcher = Application.get_env(:pincer, :line_event_dispatcher)

    System.put_env("PINCER_TEST_LINE_SECRET", @secret)

    Application.put_env(:pincer, :line_channel_config, %{
      "secret_env" => "PINCER_TEST_LINE_SECRET",
      "webhook" => %{"path" => "/webhooks/line"}
    })

    parent = self()

    Application.put_env(:pincer, :line_event_dispatcher, fn events ->
      send(parent, {:events, events})
      :ok
    end)

    on_exit(fn ->
      restore_env("PINCER_TEST_LINE_SECRET", original_secret)

      if original_config,
        do: Application.put_env(:pincer, :line_channel_config, original_config),
        else: Application.delete_env(:pincer, :line_channel_config)

      if original_dispatcher,
        do: Application.put_env(:pincer, :line_event_dispatcher, original_dispatcher),
        else: Application.delete_env(:pincer, :line_event_dispatcher)
    end)

    :ok
  end

  test "accepts signed text events and dispatches them" do
    body = Jason.encode!(%{"events" => [event()]})
    conn = signed_conn(body) |> Webhook.call([])

    assert conn.status == 200
    assert_received {:events, [event]}
    assert event.user_id == "U123"
    assert event.text == "hello"
    assert event.chat_id == "U123"
    assert event.source_type == "user"
  end

  test "rejects an invalid signature" do
    body = Jason.encode!(%{"events" => [event()]})

    conn =
      conn(:post, "/webhooks/line", body)
      |> put_req_header("x-line-signature", "invalid")
      |> Webhook.call([])

    assert conn.status == 401
  end

  test "rejects malformed signed JSON" do
    body = "{not-json"
    conn = signed_conn(body) |> Webhook.call([])

    assert conn.status == 400
  end

  defp event do
    %{
      "type" => "message",
      "replyToken" => "reply-token",
      "source" => %{"type" => "user", "userId" => "U123"},
      "message" => %{"type" => "text", "text" => "hello"}
    }
  end

  defp signed_conn(body) do
    signature = :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode64()

    conn(:post, "/webhooks/line", body)
    |> put_req_header("x-line-signature", signature)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
