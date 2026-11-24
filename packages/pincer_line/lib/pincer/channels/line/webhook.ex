defmodule Pincer.Channels.Line.Webhook do
  @moduledoc """
  Inbound LINE Messaging API webhook endpoint.

  Validates `X-Line-Signature` with the configured channel secret, parses
  text-message events, and routes them into Pincer sessions.
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
          conn.request_path != "/webhooks/line" ->
        conn |> send_resp(404, "not found") |> halt()

      secret(config) in [nil, ""] ->
        conn |> send_resp(503, "webhook not configured") |> halt()

      true ->
        with {:ok, body, conn} <- read_body(conn, length: @max_body_bytes),
             {:ok, _events} <- dispatch(body, signature(conn), config) do
          conn |> send_resp(200, "ok")
        else
          {:more, _partial, conn} ->
            conn |> send_resp(413, "payload too large") |> halt()

          {:error, :invalid_signature} ->
            conn |> send_resp(401, "invalid signature") |> halt()

          {:error, reason} ->
            Logger.warning("[LINE] webhook rejected: #{inspect(reason)}")
            conn |> send_resp(400, "bad request") |> halt()
        end
    end
  end

  defp dispatch(body, signature, _config) do
    case Pincer.Channels.Line.handle_webhook(body, signature) do
      {:ok, events} ->
        dispatcher = Application.get_env(:pincer, :line_event_dispatcher, &handle_events/1)

        case dispatcher.(events) do
          :ok -> {:ok, events}
          {:error, reason} -> {:error, reason}
          _ -> {:ok, events}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_events(events) do
    Enum.each(events, fn event ->
      case Pincer.Channels.Line.handle_event(event) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("[LINE] event dispatch failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp signature(conn) do
    conn.req_headers
    |> Enum.find_value(fn {key, value} -> if key == "x-line-signature", do: value end)
  end

  defp secret(config) do
    env = Map.get(config, "secret_env", "LINE_CHANNEL_SECRET")
    System.get_env(env)
  end

  defp channel_config do
    Application.get_env(:pincer, :line_channel_config, %{})
  end
end
