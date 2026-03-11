defmodule Pincer.LLM.Providers.Mistral do
  @moduledoc """
  Adapter for Mistral AI API.

  Particularities:
  - Endpoint: `https://api.mistral.ai/v1/chat/completions`.
  - OpenAI-compatible layout but `choices[0].delta.role` may be absent in the
    initial streaming events; this adapter tolerates that omission gracefully.
  - `list_models/1` via `GET /v1/models`.
  - API key via `MISTRAL_API_KEY` environment variable.
  """
  @behaviour Pincer.LLM.Provider

  require Logger

  @base_url "https://api.mistral.ai/v1/chat/completions"
  @models_url "https://api.mistral.ai/v1/models"
  @timeout 300_000

  @impl true
  def chat_completion(messages, model, config, tools) do
    config = normalize_config(config)
    Pincer.LLM.Providers.OpenAICompat.chat_completion(messages, model, config, tools)
  end

  @impl true
  def stream_completion(messages, model, config, tools) do
    config = normalize_config(config)
    api_key = config[:api_key]

    if is_nil(api_key) or api_key == "" do
      Logger.warning("[Mistral] No API key configured. Falling back to single-shot completion.")
      fallback_stream(messages, model, config, tools)
    else
      clean_messages = Enum.map(messages, &clean_message/1)
      body = build_stream_body(clean_messages, model, tools, config)

      case Req.post(@base_url,
             json: body,
             auth: {:bearer, api_key},
             receive_timeout: @timeout,
             into: :self
           ) do
        {:ok, response} ->
          collect_mistral_sse(response)

        {:error, reason} ->
          Logger.error("[Mistral] Stream request failed: #{inspect(reason)}")
          fallback_stream(messages, model, config, tools)
      end
    end
  end

  @impl true
  def list_models(config) do
    config = normalize_config(config)
    api_key = config[:api_key]

    if is_nil(api_key) or api_key == "" do
      {:ok, ["mistral-large-latest", "mistral-small-latest", "open-mistral-7b"]}
    else
      case Req.get(@models_url,
             auth: {:bearer, api_key},
             receive_timeout: 10_000,
             retry: :safe_transient
           ) do
        {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
          models =
            data
            |> Enum.map(& &1["id"])
            |> Enum.reject(&is_nil/1)
            |> Enum.sort()

          {:ok, models}

        {:ok, response} ->
          Logger.warning("[Mistral] Unexpected response listing models: #{response.status}")
          {:error, :unexpected_response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def transcribe_audio(_file_path, _model, _config), do: {:error, :not_implemented}

  @impl true
  def generate_embedding(text, model, config) do
    config = normalize_config(config)
    Pincer.LLM.Providers.OpenAICompat.generate_embedding(text, model, config)
  end

  # --- Private helpers ---

  defp normalize_config(config) do
    api_key = config[:api_key] || System.get_env("MISTRAL_API_KEY") || ""
    config |> Map.put_new(:base_url, @base_url) |> Map.put(:api_key, api_key)
  end

  defp build_stream_body(messages, model, tools, config) do
    body = %{model: model, messages: messages, stream: true}
    body = if Enum.empty?(tools), do: body, else: Map.put(body, :tools, tools)

    if is_number(config[:temperature]) do
      Map.put(body, :temperature, config[:temperature])
    else
      body
    end
  end

  defp fallback_stream(messages, model, config, tools) do
    case chat_completion(messages, model, config, tools) do
      {:ok, message, _usage} ->
        content = message["content"] || ""
        {:ok, [%{"choices" => [%{"delta" => %{"content" => content}}]}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_mistral_sse(response) do
    if response.status != 200 do
      body = inspect(response.body)
      Logger.error("[Mistral] SSE stream error (#{response.status}): #{body}")
      {:error, {:http_error, response.status, body}}
    else
      chunks = drain_sse_messages(response, [])
      {:ok, chunks}
    end
  end

  defp drain_sse_messages(response, acc) do
    receive do
      {^response, {:data, data}} ->
        new_chunks = parse_sse_data(data)
        drain_sse_messages(response, acc ++ new_chunks)

      {^response, :done} ->
        acc

      {^response, {:error, reason}} ->
        Logger.error("[Mistral] SSE stream read error: #{inspect(reason)}")
        acc
    after
      @timeout ->
        Logger.warning("[Mistral] SSE stream timed out.")
        acc
    end
  end

  # Mistral may omit `delta.role` in early events; we normalise here.
  defp parse_sse_data(raw) when is_binary(raw) do
    raw
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      stripped = String.trim(line)

      cond do
        stripped == "data: [DONE]" ->
          []

        String.starts_with?(stripped, "data: ") ->
          json_str = String.slice(stripped, 6, byte_size(stripped) - 6)

          case Jason.decode(json_str) do
            {:ok, parsed} ->
              [normalize_mistral_chunk(parsed)]

            {:error, _} ->
              []
          end

        true ->
          []
      end
    end)
  end

  defp parse_sse_data(_raw), do: []

  # Ensures `delta` always exists and tolerates absent `role` field.
  defp normalize_mistral_chunk(%{"choices" => choices} = parsed) when is_list(choices) do
    normalized =
      Enum.map(choices, fn choice ->
        delta = Map.get(choice, "delta") || %{}
        # Mistral may omit role in streaming deltas; default to "assistant"
        delta = Map.put_new(delta, "role", "assistant")
        %{"delta" => delta, "finish_reason" => choice["finish_reason"]}
      end)

    Map.put(parsed, "choices", normalized)
  end

  defp normalize_mistral_chunk(parsed), do: parsed

  defp clean_message(msg) when is_map(msg) do
    msg
    |> Enum.reject(fn
      {"tool_calls", nil} -> true
      {"tool_calls", []} -> true
      {:tool_calls, nil} -> true
      {:tool_calls, []} -> true
      {_, nil} -> true
      _ -> false
    end)
    |> Map.new()
  end
end
