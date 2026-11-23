defmodule Pincer.Channels.Webhook.Plug do
  @moduledoc """
  HTTP entrypoint for the webhook channel.

  The plug authenticates requests before reading their bodies, enforces the
  configured content type and body size, decodes the JSON payload, and hands it
  to an ingest function. It is a plain `Plug` module because the accepted path
  is runtime configuration.

  Accepted options:

    * `:token` - required expected token (compared in constant time)
    * `:path` - POST path, defaults to `"/webhook/message"` (`"/webhook"` is
      always accepted as an alias)
    * `:max_body_bytes` - hard body size cap, defaults to `1_048_576`
    * `:ingest_fun` - arity-2 function receiving `(payload, opts)`, defaults to
      `&Pincer.Channels.Webhook.ingest/2`

  The plug never logs tokens or payload bodies.
  """

  @behaviour Plug

  import Plug.Conn

  @default_path "/webhook/message"
  @alias_path "/webhook"
  @default_max_body_bytes 1_048_576
  @read_length 64_000
  @read_timeout 10_000

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    opts = normalize_opts(opts)

    cond do
      not known_path?(conn.request_path, opts.path) ->
        send_error(conn, 404, "not_found")

      conn.method != "POST" ->
        send_error(conn, 405, "method_not_allowed")

      not authorized?(conn, opts.token) ->
        send_error(conn, 401, "unauthorized")

      not json_content_type?(conn) ->
        send_error(conn, 415, "unsupported_media_type")

      true ->
        read_and_dispatch(conn, opts)
    end
  end

  defp read_and_dispatch(conn, opts) do
    case read_body(conn,
           length: opts.max_body_bytes,
           read_length: @read_length,
           read_timeout: @read_timeout
         ) do
      {:ok, body, conn} ->
        if byte_size(body) > opts.max_body_bytes do
          send_error(conn, 413, "payload_too_large")
        else
          decode_and_dispatch(conn, body, opts)
        end

      {:more, _partial_body, conn} ->
        send_error(conn, 413, "payload_too_large")

      {:error, :too_large} ->
        send_error(conn, 413, "payload_too_large")

      {:error, _reason} ->
        send_error(conn, 400, "invalid_body")
    end
  end

  defp decode_and_dispatch(conn, body, opts) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) ->
        dispatch(conn, payload, opts)

      _ ->
        send_error(conn, 400, "invalid_json")
    end
  end

  defp dispatch(conn, payload, opts) do
    result = opts.ingest_fun.(payload, token: opts.token, headers: Map.new(conn.req_headers))
    render(conn, result)
  end

  defp render(conn, {:ok, %{status: :accepted} = result}) do
    send_json(conn, 202, %{status: "accepted", session_id: Map.get(result, :session_id)})
  end

  defp render(conn, {:ok, %{status: :duplicate} = result}) do
    send_json(conn, 200, %{status: "duplicate", session_id: Map.get(result, :session_id)})
  end

  defp render(conn, {:error, :unauthorized}), do: send_error(conn, 401, "unauthorized")
  defp render(conn, {:error, :invalid_payload}), do: send_error(conn, 422, "invalid_payload")

  defp render(conn, {:error, :channel_unavailable}) do
    send_error(conn, 503, "channel_unavailable")
  end

  defp render(conn, {:error, _reason}), do: send_error(conn, 500, "internal_error")
  defp render(conn, _result), do: send_error(conn, 500, "internal_error")

  defp authorized?(conn, expected_token)
       when is_binary(expected_token) and expected_token != "" do
    case extract_token(conn) do
      provided when is_binary(provided) ->
        Plug.Crypto.secure_compare(provided, expected_token)

      _ ->
        false
    end
  end

  defp authorized?(_conn, _expected_token), do: false

  defp extract_token(conn) do
    request_token(conn) || authorization_token(header_value(conn, "authorization"))
  end

  defp request_token(conn) do
    case header_value(conn, "x-pincer-token") do
      nil -> nil
      value -> non_empty(value)
    end
  end

  defp authorization_token(nil), do: nil

  defp authorization_token(value) do
    value = String.trim(value)

    case String.split(value, ~r/\s+/, parts: 2) do
      [scheme, token] ->
        if String.downcase(scheme) == "bearer",
          do: non_empty(String.trim(token)),
          else: non_empty(value)

      [_single] ->
        non_empty(value)
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp header_value(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp json_content_type?(conn) do
    case header_value(conn, "content-type") do
      nil ->
        false

      value ->
        value
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase()
        |> Kernel.==("application/json")
    end
  end

  defp known_path?(request_path, configured_path) do
    request_path == configured_path or request_path == @alias_path
  end

  defp send_error(conn, status, error) do
    send_json(conn, status, %{error: error})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp normalize_opts(opts) do
    %{
      token: read_opt(opts, :token, nil),
      path: normalize_path(read_opt(opts, :path, @default_path)),
      max_body_bytes:
        normalize_max_body_bytes(read_opt(opts, :max_body_bytes, @default_max_body_bytes)),
      ingest_fun: read_opt(opts, :ingest_fun, &Pincer.Channels.Webhook.ingest/2)
    }
  end

  defp read_opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp read_opt(opts, key, default) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key)) || default
  end

  defp normalize_path(path) when is_binary(path) and path != "", do: path
  defp normalize_path(_path), do: @default_path

  defp normalize_max_body_bytes(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_body_bytes(_value), do: @default_max_body_bytes
end
