defmodule Pincer.Channels.Feishu.WebhookTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Pincer.Channels.Feishu.Webhook

  @encrypt_key "test-encrypt-key"
  @verification_token "test-verification-token"

  setup do
    original_config = Application.get_env(:pincer, :feishu_channel_config)
    original_key = System.get_env("PINCER_TEST_FEISHU_ENCRYPT_KEY")
    original_token = System.get_env("PINCER_TEST_FEISHU_VERIFY_TOKEN")

    System.put_env("PINCER_TEST_FEISHU_ENCRYPT_KEY", @encrypt_key)
    System.put_env("PINCER_TEST_FEISHU_VERIFY_TOKEN", @verification_token)

    Application.put_env(:pincer, :feishu_channel_config, %{
      "webhook" => %{
        "path" => "/webhooks/feishu",
        "encrypt_key_env" => "PINCER_TEST_FEISHU_ENCRYPT_KEY",
        "verification_token_env" => "PINCER_TEST_FEISHU_VERIFY_TOKEN"
      }
    })

    on_exit(fn ->
      restore_env("PINCER_TEST_FEISHU_ENCRYPT_KEY", original_key)
      restore_env("PINCER_TEST_FEISHU_VERIFY_TOKEN", original_token)

      if original_config,
        do: Application.put_env(:pincer, :feishu_channel_config, original_config),
        else: Application.delete_env(:pincer, :feishu_channel_config)
    end)

    :ok
  end

  test "answers URL verification challenges" do
    body =
      Jason.encode!(%{
        "type" => "url_verification",
        "challenge" => "challenge-123",
        "token" => @verification_token
      })

    conn = signed_conn(body) |> Webhook.call([])

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"challenge" => "challenge-123"}
  end

  test "rejects invalid signatures" do
    body = Jason.encode!(%{"type" => "url_verification", "challenge" => "x"})

    conn =
      conn(:post, "/webhooks/feishu", body)
      |> put_req_header("x-lark-request-timestamp", "123")
      |> put_req_header("x-lark-request-nonce", "nonce")
      |> put_req_header("x-lark-signature", "invalid")
      |> Webhook.call([])

    assert conn.status == 401
  end

  test "decrypts encrypted event payloads" do
    parent = self()

    payload = %{
      "schema" => "2.0",
      "event" => %{
        "sender" => %{"sender_id" => %{"open_id" => "ou_encrypted"}},
        "message" => %{
          "chat_id" => "oc_encrypted",
          "message_id" => "om_encrypted",
          "message_type" => "text",
          "content" => Jason.encode!(%{"text" => "secret hello"})
        }
      }
    }

    body = Jason.encode!(%{"encrypt" => encrypt(payload)})

    conn =
      signed_conn(body)
      |> Webhook.call(dispatcher: fn event -> send(parent, {:event, event}) end)

    assert conn.status == 200
    assert_received {:event, event}
    assert event.chat_id == "oc_encrypted"
    assert event.content == "secret hello"
  end

  test "dispatches parsed message events" do
    parent = self()

    body =
      Jason.encode!(%{
        "schema" => "2.0",
        "event" => %{
          "sender" => %{"sender_id" => %{"open_id" => "ou_1"}},
          "message" => %{
            "chat_id" => "oc_1",
            "message_id" => "om_1",
            "message_type" => "text",
            "chat_type" => "p2p",
            "content" => Jason.encode!(%{"text" => "hello"})
          }
        }
      })

    conn =
      signed_conn(body)
      |> Webhook.call(dispatcher: fn event -> send(parent, {:event, event}) end)

    assert conn.status == 200
    assert_received {:event, event}
    assert event.open_id == "ou_1"
    assert event.chat_id == "oc_1"
    assert event.content == "hello"
  end

  defp encrypt(payload) do
    plaintext = Jason.encode!(payload)
    pad = 16 - rem(byte_size(plaintext), 16)
    padded = plaintext <> :binary.copy(<<pad>>, pad)
    key = :crypto.hash(:sha256, @encrypt_key)
    iv = :crypto.strong_rand_bytes(16)

    ciphertext =
      :crypto.crypto_one_time(:aes_256_cbc, key, iv, padded, true)

    Base.encode64(iv <> ciphertext)
  end

  defp signed_conn(body) do
    timestamp = "1700000000"
    nonce = "test-nonce"

    signature =
      :crypto.hash(:sha256, timestamp <> nonce <> @encrypt_key <> body)
      |> Base.encode16(case: :lower)

    conn(:post, "/webhooks/feishu", body)
    |> put_req_header("x-lark-request-timestamp", timestamp)
    |> put_req_header("x-lark-request-nonce", nonce)
    |> put_req_header("x-lark-signature", signature)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
