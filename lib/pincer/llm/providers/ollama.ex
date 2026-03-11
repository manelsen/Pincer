defmodule Pincer.LLM.Providers.Ollama do
  @moduledoc """
  Adapter for Ollama (local LLM inference).

  Particularities:
  - Default endpoint: `POST http://localhost:11434/api/chat` (configurable via
    `base_url` in the provider config or the `OLLAMA_BASE_URL` env variable).
  - Request format uses Ollama's native schema, not OpenAI's.
  - Streaming returns newline-delimited JSON (JSON Lines), one JSON object per line,
    without the `data:` SSE prefix.
  - `list_models/1` via `GET /api/tags`.
  - No API key required.
  """
  @behaviour Pincer.LLM.Provider

  require Logger

  @default_base_url "http://localhost:11434"
  @timeout 300_000
  @connect_timeout 5_000

  @impl true
  def chat_completion(messages, model, config, tools) do
    config = normalize_config(config)
    base_url = config[:ollama_base_url]
    chat_url = "#{base_url}/api/chat"

    body = build_body(messages, model, tools, false)

    case Req.post(chat_url,
           json: body,
           receive_timeout: @timeout,
           connect_options: [timeout: @connect_timeout],
           retry: false
         ) do
      {:ok, %{status: 200, body: body_map}} when is_map(body_map) ->
        handle_chat_response(body_map)

      {:ok, %{status: status, body: body_map}} ->
        error_msg = inspect(body_map)
        Logger.error("[Ollama] HTTP error (#{status}): #{error_msg}")
        {:error, {:http_error, status, error_msg}}

      {:error, reason} ->
        Logger.error("[Ollama] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def stream_completion(messages, model, config, tools) do
    config = normalize_config(config)
    base_url = config[:ollama_base_url]
    chat_url = "#{base_url}/api/chat"

    body = build_body(messages, model, tools, true)

    case Req.post(chat_url,
           json: body,
           receive_timeout: @timeout,
           connect_options: [timeout: @connect_timeout],
           into: :self,
           retry: false
         ) do
      {:ok, response} ->
        if response.status != 200 do
          body_str = inspect(response.body)
          Logger.error("[Ollama] Stream error (#{response.status}): #{body_str}")
          {:error, {:http_error, response.status, body_str}}
        else
          chunks = drain_jsonl_stream(response, [])
          {:ok, chunks}
        end

      {:error, reason} ->
        Logger.error("[Ollama] Stream request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def list_models(config) do
    config = normalize_config(config)
    base_url = config[:ollama_base_url]
    tags_url = "#{base_url}/api/tags"

    case Req.get(tags_url,
           receive_timeout: 10_000,
           connect_options: [timeout: @connect_timeout],
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"models" => models}}} when is_list(models) ->
        ids =
          models
          |> Enum.map(& &1["name"])
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()

        {:ok, ids}

      {:ok, response} ->
        Logger.warning("[Ollama] Unexpected response listing models: #{response.status}")
        {:error, :unexpected_response}

      {:error, reason} ->
        Logger.warning("[Ollama] Could not reach Ollama at #{tags_url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def transcribe_audio(_file_path, _model, _config), do: {:error, :not_implemented}

  @impl true
  def generate_embedding(_text, _model, _config), do: {:error, :not_implemented}

  # --- Private helpers ---

  defp normalize_config(config) do
    base_url =
      config[:base_url] || System.get_env("OLLAMA_BASE_URL") || @default_base_url

    Map.put(config, :ollama_base_url, String.trim_trailing(base_url, "/"))
  end

  defp build_body(messages, model, tools, stream?) do
    body = %{model: model, messages: messages, stream: stream?}

    if Enum.empty?(tools) do
      body
    else
      Map.put(body, :tools, tools)
    end
  end

  defp handle_chat_response(%{"message" => message} = body) when is_map(message) do
    content = message["content"] || ""
    tool_calls = message["tool_calls"]

    normalized =
      %{"role" => "assistant", "content" => content}
      |> maybe_put("tool_calls", tool_calls)

    usage = body["usage"]
    {:ok, normalized, usage}
  end

  defp handle_chat_response(body) do
    Logger.error("[Ollama] Unexpected response format: #{inspect(body)}")
    {:error, :unexpected_response_format}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Drains JSON Lines from Req's `into: :self` delivery.
  # Each data message may contain one or more JSON lines separated by newlines.
  defp drain_jsonl_stream(response, acc) do
    receive do
      {^response, {:data, data}} ->
        new_chunks = parse_jsonl_data(data)
        drain_jsonl_stream(response, acc ++ new_chunks)

      {^response, :done} ->
        acc

      {^response, {:error, reason}} ->
        Logger.error("[Ollama] JSON Lines stream read error: #{inspect(reason)}")
        acc
    after
      @timeout ->
        Logger.warning("[Ollama] JSON Lines stream timed out.")
        acc
    end
  end

  # Parses a raw JSON Lines chunk into OpenAI-compatible delta chunks.
  defp parse_jsonl_data(raw) when is_binary(raw) do
    raw
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      trimmed = String.trim(line)

      if trimmed == "" do
        []
      else
        case Jason.decode(trimmed) do
          {:ok, parsed} -> [ollama_to_delta_chunk(parsed)]
          {:error, _} -> []
        end
      end
    end)
  end

  defp parse_jsonl_data(_raw), do: []

  # Converts an Ollama streaming response object into OpenAI delta format.
  defp ollama_to_delta_chunk(%{"message" => message} = _parsed) when is_map(message) do
    content = message["content"] || ""
    tool_calls = message["tool_calls"]

    delta = %{"content" => content}

    delta =
      if is_list(tool_calls) and tool_calls != [] do
        Map.put(delta, "tool_calls", tool_calls)
      else
        delta
      end

    %{"choices" => [%{"delta" => delta}]}
  end

  defp ollama_to_delta_chunk(_parsed) do
    %{"choices" => [%{"delta" => %{"content" => ""}}]}
  end
end
