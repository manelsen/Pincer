defmodule Pincer.Channels.DingTalk.WebhookTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Pincer.Channels.DingTalk.Webhook

  @secret "dingtalk-test-secret"

  setup do
    original_config = Application.get_env(:pincer, :dingtalk_channel_config)
    original_secret = System.get_env("PINCER_TEST_DINGTALK_SIGNING_SECRET")
    original_dispatcher = Application.get_env(:pincer, :dingtalk_event_dispatcher)

    System.put_env("PINCER_TEST_DINGTALK_SIGNING_SECRET", @secret)

    Application.put_env(:pincer, :dingtalk_channel_config, %{
      "signing_secret_env" => "PINCER_TEST_DINGTALK_SIGNING_SECRET",
      "webhook" => %{"path" => "/webhooks/dingtalk"}
    })

    parent = self()

    Application.put_env(:pincer, :dingtalk_event_dispatcher, fn event ->
      send(parent, {:event, event})
      :ok
    end)

    on_exit(fn ->
      restore_env("PINCER_TEST_DINGTALK_SIGNING_SECRET", original_secret)

      if original_config,
        do: Application.put_env(:pincer, :dingtalk_channel_config, original_config),
        else: Application.delete_env(:pincer, :dingtalk_channel_config)

      if original_dispatcher,
        do: Application.put_env(:pincer, :dingtalk_event_dispatcher, original_dispatcher),
        else: Application.delete_env(:pincer, :dingtalk_event_dispatcher)
    end)

    :ok
  end

  test "accepts signed events and dispatches them" do
    body = Jason.encode!(payload())
    conn = signed_conn(body) |> Webhook.call([])

    assert conn.status == 200
    assert_received {:event, event}
    assert event.staff_id == "staff1"
    assert event.conversation_id == "cid_group"
    assert event.text == "hello"
  end

  test "rejects an invalid signature" do
    body = Jason.encode!(payload())

    conn =
      conn(:post, "/webhooks/dingtalk", body)
      |> put_req_header("timestamp", "1700000000")
      |> put_req_header("sign", "invalid")
      |> Webhook.call([])

    assert conn.status == 401
  end

  test "rejects encrypted event bodies explicitly" do
    body = Jason.encode!(%{"encrypt" => "ciphertext"})
    conn = signed_conn(body) |> Webhook.call([])

    assert conn.status == 400
    assert conn.resp_body =~ "encrypted"
  end

  defp payload do
    %{
      "msgtype" => "text",
      "text" => %{"content" => "hello"},
      "senderStaffId" => "staff1",
      "conversationId" => "cid_group"
    }
  end

  defp signed_conn(body) do
    timestamp = "1700000000"
    string_to_sign = timestamp <> "\n" <> @secret
    signature = :crypto.mac(:hmac, :sha256, @secret, string_to_sign) |> Base.encode64()

    conn(:post, "/webhooks/dingtalk", body)
    |> put_req_header("timestamp", timestamp)
    |> put_req_header("sign", signature)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
