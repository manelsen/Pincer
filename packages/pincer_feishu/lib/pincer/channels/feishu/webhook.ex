defmodule Pincer.Channels.Feishu.Webhook do
  @moduledoc """
  Inbound Feishu/Lark webhook endpoint.

  Verifies the Feishu signature with the configured encrypt key, decrypts
  encrypted event payloads, answers URL-verification challenges, and routes
  message events into Pincer sessions.

  Verification is fail-closed: without an encrypt key the endpoint returns
  `503` instead of accepting unauthenticated events.
  """

  @behaviour Plug
  import Plug.Conn

  require Logger

  @max_body_bytes 1_048_576

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    config = channel_config()

    if conn.method != "POST" do
      conn |> send_resp(405, "method not allowed") |> halt()
    else
      with :ok <- verify_path(conn, config),
           {:ok, body, conn} <- read_body(conn, length: @max_body_bytes),
           :ok <- verify_signature(conn, body, config),
           {:ok, payload} <- decode_payload(body, config) do
        handle_payload(payload, conn, opts)
      else
        {:error, :not_found} -> conn |> send_resp(404, "not found") |> halt()
        {:error, :invalid_signature} -> conn |> send_resp(401, "invalid signature") |> halt()
        {:error, :missing_encrypt_key} -> conn |> send_resp(503, "webhook not configured") |> halt()
        {:more, _partial, conn} -> conn |> send_resp(413, "payload too large") |> halt()
        {:error, _reason} -> conn |> send_resp(400, "bad request") |> halt()
      end
    end
  end

  defp verify_path(conn, config) do
    expected = get_in(config, ["webhook", "path"]) || "/webhooks/feishu"

    if conn.request_path == expected, do: :ok, else: {:error, :not_found}
  end

  defp verify_signature(conn, body, config) do
    encrypt_key = encrypt_key(config)

    if encrypt_key in [nil, ""] do
      {:error, :missing_encrypt_key}
    else
      timestamp = header(conn, "x-lark-request-timestamp")
      nonce = header(conn, "x-lark-request-nonce")
      signature = header(conn, "x-lark-signature")

      cond do
        is_nil(timestamp) or is_nil(nonce) or is_nil(signature) ->
          {:error, :invalid_signature}

        true ->
          Pincer.Channels.Shared.WebhookVerifier.verify_feishu(
            timestamp,
            nonce,
            body,
            signature,
            encrypt_key
          )
      end
    end
  end

  defp decode_payload(body, config) do
    with {:ok, payload} <- Jason.decode(body) do
      case payload do
        %{"encrypt" => encrypted} -> decrypt(encrypted, encrypt_key(config))
        payload -> {:ok, payload}
      end
    end
  end

  defp decrypt(encrypted, encrypt_key) when is_binary(encrypt_key) and encrypt_key != "" do
    with {:ok, raw} <- Base.decode64(encrypted),
         <<iv::binary-size(16), ciphertext::binary>> <- raw,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time(
             :aes_256_cbc,
             :crypto.hash(:sha256, encrypt_key),
             iv,
             ciphertext,
             false
           ),
         {:ok, unpadded} <- unpad(plaintext) do
      Jason.decode(unpadded)
    else
      _ -> {:error, :invalid_payload}
    end
  rescue
    _ -> {:error, :invalid_payload}
  end

  defp decrypt(_encrypted, _encrypt_key), do: {:error, :missing_encrypt_key}

  defp unpad(plaintext) when byte_size(plaintext) > 0 do
    pad = :binary.last(plaintext)
    size = byte_size(plaintext)

    if pad in 1..16 and pad <= size do
      {:ok, binary_part(plaintext, 0, size - pad)}
    else
      {:error, :invalid_padding}
    end
  end

  defp unpad(_plaintext), do: {:error, :invalid_padding}

  defp handle_payload(%{"type" => "url_verification"} = payload, conn, _opts) do
    config = channel_config()

    if valid_verification_token?(payload["token"], config) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"challenge" => payload["challenge"]}))
    else
      conn |> send_resp(401, "invalid token") |> halt()
    end
  end

  defp handle_payload(payload, conn, opts) do
    event = Pincer.Channels.Feishu.parse_webhook_event(payload)
    dispatcher = Keyword.get(opts, :dispatcher, &Pincer.Channels.Feishu.handle_event/1)

    case event do
      :error ->
        conn |> send_resp(200, "ignored")

      event ->
        case dispatcher.(event) do
          :ok ->
            conn |> send_resp(200, "ok")

          {:error, reason} ->
            Logger.warning("[FEISHU] event dispatch failed: #{inspect(reason)}")
            conn |> send_resp(200, "accepted")

          _other ->
            conn |> send_resp(200, "ok")
        end
    end
  end

  defp valid_verification_token?(token, config) do
    expected_env =
      get_in(config, ["webhook", "verification_token_env"]) || "FEISHU_VERIFICATION_TOKEN"

    expected = System.get_env(expected_env)

    is_binary(expected) and is_binary(token) and byte_size(expected) == byte_size(token) and
      :crypto.hash_equals(expected, token)
  end

  defp encrypt_key(config) do
    env = get_in(config, ["webhook", "encrypt_key_env"]) || "FEISHU_ENCRYPT_KEY"
    System.get_env(env)
  end

  defp header(conn, name) do
    conn.req_headers
    |> Enum.find_value(fn {key, value} -> if key == name, do: value end)
  end

  defp channel_config do
    Application.get_env(:pincer, :feishu_channel_config, %{})
  end
end
