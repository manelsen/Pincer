defmodule Pincer.Channels.DingTalk.Webhook do
  @moduledoc """
  Inbound DingTalk robot event endpoint.

  Verifies the DingTalk timestamp signature with the configured signing
  secret and routes robot message events into Pincer sessions. Encrypted
  event bodies are rejected explicitly rather than processed unverified.
  """

  @behaviour Plug
  import Plug.Conn

  require Logger

  @max_body_bytes 1_048_576

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    config = channel_config()

    cond do
      conn.method != "POST" ->
        conn |> send_resp(405, "method not allowed") |> halt()

      conn.request_path != get_in(config, ["webhook", "path"]) &&
          conn.request_path != "/webhooks/dingtalk" ->
        conn |> send_resp(404, "not found") |> halt()

      signing_secret(config) in [nil, ""] ->
        conn |> send_resp(503, "webhook not configured") |> halt()

      true ->
        with {:ok, body, conn} <- read_body(conn, length: @max_body_bytes),
             :ok <- verify(conn, body, config),
             {:ok, payload} <- decode(body),
             {:ok, event} <- parse(payload) do
          dispatch(event)
          conn |> send_resp(200, "ok")
        else
          {:more, _partial, conn} ->
            conn |> send_resp(413, "payload too large") |> halt()

          {:error, :invalid_signature} ->
            conn |> send_resp(401, "invalid signature") |> halt()

          {:error, :encrypted_payload} ->
            conn |> send_resp(400, "encrypted payloads are not supported") |> halt()

          {:error, reason} ->
            Logger.warning("[DINGTALK] webhook rejected: #{inspect(reason)}")
            conn |> send_resp(400, "bad request") |> halt()
        end
    end
  end

  defp verify(conn, _body, config) do
    timestamp = header_or_param(conn, ["timestamp", "x-dingtalk-timestamp"])
    signature = header_or_param(conn, ["sign", "x-dingtalk-signature"])

    if is_nil(timestamp) or is_nil(signature) do
      {:error, :invalid_signature}
    else
      Pincer.Channels.DingTalk.validate_webhook(
        timestamp,
        signing_secret(config),
        signature
      )
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"encrypt" => _encrypted}} -> {:error, :encrypted_payload}
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_payload}
    end
  end

  defp parse(payload) do
    case Pincer.Channels.DingTalk.parse_webhook_event(payload) do
      :error -> {:error, :invalid_event}
      event -> {:ok, event}
    end
  end

  defp dispatch(event) do
    dispatcher = Application.get_env(:pincer, :dingtalk_event_dispatcher, &default_dispatch/1)
    dispatcher.(event)
  end

  defp default_dispatch(event) do
    case Pincer.Channels.DingTalk.handle_event(event) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[DINGTALK] event dispatch failed: #{inspect(reason)}")
    end
  end

  defp header_or_param(conn, names) do
    Enum.find_value(names, fn name ->
      conn.req_headers
      |> Enum.find_value(fn {key, value} -> if key == name, do: value end)
      |> case do
        nil -> conn.query_params[name]
        value -> value
      end
    end)
  end

  defp signing_secret(config) do
    env = Map.get(config, "signing_secret_env", "DINGTALK_SIGNING_SECRET")
    System.get_env(env)
  end

  defp channel_config do
    Application.get_env(:pincer, :dingtalk_channel_config, %{})
  end
end
