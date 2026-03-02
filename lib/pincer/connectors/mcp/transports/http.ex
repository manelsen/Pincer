defmodule Pincer.Connectors.MCP.Transports.HTTP do
  @moduledoc """
  HTTP transport implementation for MCP servers.

  This transport targets MCP servers exposed over HTTP streamable endpoints.
  Each JSON-RPC payload is sent as an HTTP POST and responses are forwarded to
  the transport owner as `{:mcp_transport, message}`.

  Supports both:
  - JSON response body (`application/json`)
  - SSE stream body (`text/event-stream`) with incremental `data: ...` events

  Long-lived SSE streams are hardened with:
  - heartbeat/comment filtering;
  - retry with exponential backoff for transient interruptions;
  - payload dedupe across reconnect attempts.
  """

  @behaviour Pincer.Connectors.MCP.Transport

  @default_max_reconnect_attempts 3
  @default_initial_backoff_ms 200
  @default_max_backoff_ms 2_000

  @heartbeat_events MapSet.new(["heartbeat", "ping", "keepalive"])
  @heartbeat_payload_values MapSet.new(["heartbeat", "ping", "keepalive"])
  @retryable_http_statuses MapSet.new([408, 425, 429, 500, 502, 503, 504])

  @retryable_transport_reasons MapSet.new([
                                 :timeout,
                                 :connect_timeout,
                                 :closed,
                                 :econnrefused,
                                 :enetunreach,
                                 :ehostunreach
                               ])

  @type requester :: (String.t(), map(), [{String.t(), String.t()}] ->
                        {:ok, any()} | {:error, any()})
  @type closer :: (t() -> any())
  @type sleep_fn :: (non_neg_integer() -> any())

  @type t :: %__MODULE__{
          url: String.t(),
          headers: [{String.t(), String.t()}],
          owner: pid(),
          requester: requester(),
          closer: closer(),
          max_reconnect_attempts: non_neg_integer(),
          initial_backoff_ms: pos_integer(),
          max_backoff_ms: pos_integer(),
          sleep_fn: sleep_fn()
        }

  @type sse_parse_result :: %{
          messages: [map()],
          done?: boolean(),
          last_event_id: String.t() | nil
        }

  defstruct [
    :url,
    :headers,
    :owner,
    :requester,
    :closer,
    :max_reconnect_attempts,
    :initial_backoff_ms,
    :max_backoff_ms,
    :sleep_fn
  ]

  @impl true
  @spec connect(keyword()) :: {:ok, t()} | {:error, :missing_url}
  def connect(opts) do
    url = Keyword.get(opts, :url) || Keyword.get(opts, :base_url)

    if present?(url) do
      initial_backoff_ms =
        normalize_positive_integer(
          Keyword.get(opts, :initial_backoff_ms),
          @default_initial_backoff_ms
        )

      max_backoff_ms =
        normalize_positive_integer(Keyword.get(opts, :max_backoff_ms), @default_max_backoff_ms)

      {:ok,
       %__MODULE__{
         url: url,
         headers: normalize_headers(Keyword.get(opts, :headers, [])),
         owner: Keyword.get(opts, :owner, self()),
         requester: Keyword.get(opts, :requester, &default_requester/3),
         closer: Keyword.get(opts, :closer, fn _state -> :ok end),
         max_reconnect_attempts:
           normalize_non_neg_integer(
             Keyword.get(opts, :max_reconnect_attempts),
             @default_max_reconnect_attempts
           ),
         initial_backoff_ms: initial_backoff_ms,
         max_backoff_ms: max(max_backoff_ms, initial_backoff_ms),
         sleep_fn: normalize_sleep_fn(Keyword.get(opts, :sleep_fn))
       }}
    else
      {:error, :missing_url}
    end
  end

  @impl true
  @spec send_message(t(), map()) :: :ok | {:error, any()}
  def send_message(%__MODULE__{} = state, message) when is_map(message) do
    do_send_message(state, message, 0, MapSet.new(), nil)
  rescue
    error -> {:error, error}
  end

  def send_message(_state, _message), do: {:error, :invalid_message}

  @impl true
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = state) do
    state.closer.(state)
    :ok
  rescue
    _error -> :ok
  end

  defp do_send_message(state, message, attempt, seen_payloads, last_event_id) do
    request_headers = request_headers(state.headers, last_event_id)

    case state.requester.(state.url, message, request_headers) do
      {:ok, response} ->
        case parse_transport_response(response) do
          {:ok, {:single, payload}} ->
            send(state.owner, {:mcp_transport, payload})
            :ok

          {:ok, {:sse, sse_result}} ->
            handle_sse_result(state, message, attempt, seen_payloads, sse_result)

          {:error, reason} ->
            maybe_retry(state, message, attempt, reason, seen_payloads, last_event_id)
        end

      {:error, reason} ->
        maybe_retry(state, message, attempt, reason, seen_payloads, last_event_id)
    end
  end

  defp handle_sse_result(state, message, attempt, seen_payloads, sse_result) do
    {new_messages, updated_seen} = dedupe_messages(sse_result.messages, seen_payloads)
    maybe_send_sse_messages(state.owner, new_messages)

    if sse_result.done? do
      :ok
    else
      reason = {:stream_closed_without_done, %{received: length(sse_result.messages)}}
      maybe_retry(state, message, attempt, reason, updated_seen, sse_result.last_event_id)
    end
  end

  defp parse_transport_response(%Req.Response{
         status: status,
         body: body,
         headers: headers
       }) do
    parse_http_response(status, headers, body)
  end

  defp parse_transport_response(%{status: status, body: body} = response)
       when is_integer(status) do
    headers = Map.get(response, :headers) || Map.get(response, "headers", %{})
    parse_http_response(status, headers, body)
  end

  defp parse_transport_response(%{} = body), do: {:ok, {:single, body}}
  defp parse_transport_response(other), do: {:error, {:invalid_http_response, other}}

  defp parse_http_response(status, headers, body) when status >= 200 and status < 300 do
    cond do
      sse_content_type?(headers) ->
        with {:ok, parsed} <- parse_sse_messages(body) do
          {:ok, {:sse, parsed}}
        end

      is_map(body) ->
        {:ok, {:single, body}}

      true ->
        {:error, {:invalid_response_body, body}}
    end
  end

  defp parse_http_response(status, _headers, body),
    do: {:error, {:http_error, status, body}}

  defp maybe_retry(state, message, attempt, reason, seen_payloads, last_event_id) do
    if retryable_error?(reason) and attempt < state.max_reconnect_attempts do
      backoff_ms = reconnect_backoff_ms(state, attempt)
      state.sleep_fn.(backoff_ms)
      do_send_message(state, message, attempt + 1, seen_payloads, last_event_id)
    else
      {:error, reason}
    end
  end

  defp reconnect_backoff_ms(state, attempt) do
    value =
      state.initial_backoff_ms
      |> Kernel.*(round(:math.pow(2, attempt)))

    min(value, state.max_backoff_ms)
  end

  defp dedupe_messages(messages, seen_payloads) do
    Enum.reduce(messages, {[], seen_payloads}, fn message, {acc, seen} ->
      signature = payload_signature(message)

      if MapSet.member?(seen, signature) do
        {acc, seen}
      else
        {[message | acc], MapSet.put(seen, signature)}
      end
    end)
    |> then(fn {messages_rev, new_seen} -> {Enum.reverse(messages_rev), new_seen} end)
  end

  defp payload_signature(message) when is_map(message) do
    :erlang.term_to_binary(message)
  end

  defp maybe_send_sse_messages(_owner, []), do: :ok

  defp maybe_send_sse_messages(owner, messages) do
    send(owner, {:mcp_transport, messages})
  end

  defp request_headers(base_headers, nil), do: base_headers

  defp request_headers(base_headers, last_event_id) do
    cleaned =
      Enum.reject(base_headers, fn {name, _value} ->
        String.downcase(to_string(name)) == "last-event-id"
      end)

    cleaned ++ [{"Last-Event-ID", last_event_id}]
  end

  defp parse_sse_messages(body) when is_list(body) do
    body
    |> Enum.map(&to_string/1)
    |> Enum.join("")
    |> parse_sse_messages()
  end

  defp parse_sse_messages(body) when is_binary(body) do
    body
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.reduce_while(
      {:ok, %{messages: [], done?: false, last_event_id: nil}},
      fn event, {:ok, acc} ->
        case parse_sse_event(event) do
          :ignore ->
            {:cont, {:ok, acc}}

          {:heartbeat, event_id} ->
            {:cont, {:ok, put_last_event_id(acc, event_id)}}

          {:done, event_id} ->
            {:halt, {:ok, %{put_last_event_id(acc, event_id) | done?: true}}}

          {:ok, message, event_id} ->
            next_acc =
              acc
              |> put_last_event_id(event_id)
              |> Map.update!(:messages, fn messages -> messages ++ [message] end)

            {:cont, {:ok, next_acc}}

          {:error, _} = error ->
            {:halt, error}
        end
      end
    )
  end

  defp parse_sse_messages(body), do: {:error, {:invalid_response_body, body}}

  defp parse_sse_event(event) when is_binary(event) do
    lines = String.split(event, ~r/\r?\n/, trim: true)
    event_name = read_sse_field(lines, "event")
    event_id = read_sse_field(lines, "id")

    data =
      lines
      |> Enum.filter(&line_has_prefix?(&1, "data:"))
      |> Enum.map(fn line ->
        line
        |> String.trim_leading("data:")
        |> String.trim()
      end)
      |> Enum.join("\n")

    cond do
      data == "" and heartbeat_event?(event_name) ->
        {:heartbeat, event_id}

      data == "" ->
        :ignore

      data == "[DONE]" ->
        {:done, event_id}

      true ->
        case Jason.decode(data) do
          {:ok, %{} = message} ->
            if heartbeat_event?(event_name) or heartbeat_payload?(message) do
              {:heartbeat, event_id}
            else
              {:ok, message, event_id}
            end

          _ ->
            {:error, {:invalid_sse_data, data}}
        end
    end
  end

  defp parse_sse_event(_), do: {:error, {:invalid_sse_data, :invalid_event}}

  defp put_last_event_id(acc, nil), do: acc
  defp put_last_event_id(acc, event_id), do: %{acc | last_event_id: event_id}

  defp read_sse_field(lines, field_name) do
    prefix = String.downcase(field_name) <> ":"

    Enum.find_value(lines, fn line ->
      if line_has_prefix?(line, prefix) do
        line
        |> String.split(":", parts: 2)
        |> List.last()
        |> String.trim()
      end
    end)
  end

  defp line_has_prefix?(line, prefix) do
    String.starts_with?(String.downcase(to_string(line)), String.downcase(prefix))
  end

  defp heartbeat_event?(nil), do: false

  defp heartbeat_event?(event_name) do
    event_name
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> then(&MapSet.member?(@heartbeat_events, &1))
  end

  defp heartbeat_payload?(%{} = message) do
    heartbeat_value =
      message["type"] ||
        message[:type] ||
        message["event"] ||
        message[:event]

    case heartbeat_value do
      value when is_binary(value) ->
        MapSet.member?(@heartbeat_payload_values, String.downcase(String.trim(value)))

      _ ->
        false
    end
  end

  defp retryable_error?({:http_error, status, _body}) when is_integer(status),
    do: MapSet.member?(@retryable_http_statuses, status)

  defp retryable_error?({:stream_closed_without_done, _meta}), do: true

  defp retryable_error?(%Req.TransportError{reason: reason}) do
    MapSet.member?(@retryable_transport_reasons, reason)
  end

  defp retryable_error?(reason) when is_atom(reason),
    do: MapSet.member?(@retryable_transport_reasons, reason)

  defp retryable_error?(_), do: false

  defp sse_content_type?(headers) do
    case header_value(headers, "content-type") do
      nil -> false
      value -> value |> String.downcase() |> String.contains?("text/event-stream")
    end
  end

  defp header_value(headers, target_name) when is_map(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(to_string(name)) == target_name, do: normalize_header_value(value)
    end)
  end

  defp header_value(headers, target_name) when is_list(headers) do
    Enum.find_value(headers, fn
      {name, value} ->
        if String.downcase(to_string(name)) == target_name, do: normalize_header_value(value)

      _other ->
        nil
    end)
  end

  defp header_value(_, _), do: nil

  defp normalize_header_value(value) when is_list(value),
    do: value |> Enum.map(&to_string/1) |> Enum.join(",")

  defp normalize_header_value(value), do: to_string(value)

  defp default_requester(url, payload, headers) do
    Req.post(url, json: payload, headers: headers)
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce(headers, [], fn
      {k, v}, acc ->
        [{to_string(k), to_string(v)} | acc]

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp normalize_headers(_), do: []

  defp normalize_non_neg_integer(value, _default)
       when is_integer(value) and value >= 0,
       do: value

  defp normalize_non_neg_integer(_value, default), do: default

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(_value, default), do: default

  defp normalize_sleep_fn(fun) when is_function(fun, 1), do: fun
  defp normalize_sleep_fn(_), do: &Process.sleep/1

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
