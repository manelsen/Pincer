defmodule Pincer.LLM.Providers.OpenAI do
  @moduledoc """
  Adapter for the native OpenAI API.

  Particularities:
  - Direct integration with `https://api.openai.com/v1/chat/completions`.
  - Supports real streaming via SSE (`data: {...}` line-by-line with `into: :self`).
  - Captures `usage` from the final `data: [DONE]` event when available.
  - `list_models/1` discovers available models via `GET /v1/models`.
  - API key is read from the `OPENAI_API_KEY` environment variable.
  """
  @behaviour Pincer.LLM.Provider

  require Logger

  @base_url "https://api.openai.com/v1/chat/completions"
  @models_url "https://api.openai.com/v1/models"
  @timeout 300_000
  @connect_timeout 10_000

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
      Logger.warning("No OPENAI_API_KEY configured. Using MOCK stream mode.")

      {:ok,
       [
         %{"choices" => [%{"delta" => %{"content" => "[MOCK STREAM] Configure OPENAI_API_KEY."}}]}
       ]}
    else
      clean_messages = Enum.map(messages, &clean_message/1)
      body = build_stream_body(clean_messages, model, tools, config)
      headers = [{"authorization", "Bearer #{api_key}"}]

      case Req.post(@base_url,
             json: body,
             headers: headers,
             receive_timeout: @timeout,
             connect_options: [timeout: @connect_timeout],
             into: :self
           ) do
        {:ok, response} ->
          collect_sse_stream(response)

        {:error, reason} ->
          Logger.error("[OpenAI] Stream request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl true
  def list_models(config) do
    config = normalize_config(config)
    api_key = config[:api_key]

    if is_nil(api_key) or api_key == "" do
      {:ok, ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo"]}
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
            |> Enum.filter(&String.starts_with?(&1, "gpt-"))
            |> Enum.sort()

          {:ok, models}

        {:ok, response} ->
          Logger.warning("[OpenAI] Unexpected response listing models: #{response.status}")
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
    api_key = config[:api_key] || System.get_env("OPENAI_API_KEY") || ""
    config |> Map.put_new(:base_url, @base_url) |> Map.put(:api_key, api_key)
  end

  defp build_stream_body(messages, model, tools, config) do
    body = %{
      model: model,
      messages: messages,
      stream: true,
      stream_options: %{include_usage: true}
    }

    body = if Enum.empty?(tools), do: body, else: Map.put(body, :tools, tools)

    if is_number(config[:temperature]) do
      Map.put(body, :temperature, config[:temperature])
    else
      body
    end
  end

  defp collect_sse_stream(response) do
    if response.status != 200 do
      body = inspect(response.body)
      Logger.error("[OpenAI] SSE stream error (#{response.status}): #{body}")
      {:error, {:http_error, response.status, body}}
    else
      chunks = drain_sse_messages(response, [], nil)
      {:ok, chunks}
    end
  end

  # Drains messages sent to self() from Req's `into: :self` mode.
  # Returns a list of parsed SSE chunk maps (OpenAI delta format).
  defp drain_sse_messages(response, acc, last_usage) do
    receive do
      {^response, {:data, data}} ->
        {new_chunks, usage} = parse_sse_data(data, last_usage)
        drain_sse_messages(response, acc ++ new_chunks, usage || last_usage)

      {^response, :done} ->
        acc

      {^response, {:error, reason}} ->
        Logger.error("[OpenAI] SSE stream read error: #{inspect(reason)}")
        acc
    after
      @timeout ->
        Logger.warning("[OpenAI] SSE stream timed out waiting for messages.")
        acc
    end
  end

  # Parses a raw SSE data chunk (may contain multiple `data: ...` lines).
  # Returns `{[chunk_maps], usage | nil}`.
  defp parse_sse_data(raw, _last_usage) when is_binary(raw) do
    lines = String.split(raw, "\n")

    Enum.reduce(lines, {[], nil}, fn line, {chunks, usage} ->
      stripped = String.trim(line)

      cond do
        stripped == "data: [DONE]" ->
          {chunks, usage}

        String.starts_with?(stripped, "data: ") ->
          json_str = String.slice(stripped, 6, byte_size(stripped) - 6)

          case Jason.decode(json_str) do
            {:ok, %{"usage" => u} = parsed} when is_map(u) ->
              new_chunk = extract_delta_chunk(parsed)
              {chunks ++ [new_chunk], u}

            {:ok, parsed} ->
              new_chunk = extract_delta_chunk(parsed)
              {chunks ++ [new_chunk], usage}

            {:error, _} ->
              {chunks, usage}
          end

        true ->
          {chunks, usage}
      end
    end)
  end

  defp parse_sse_data(_raw, _last_usage), do: {[], nil}

  defp extract_delta_chunk(parsed) when is_map(parsed) do
    choices = parsed["choices"] || []

    normalized_choices =
      Enum.map(choices, fn choice ->
        %{"delta" => choice["delta"] || %{}, "finish_reason" => choice["finish_reason"]}
      end)

    %{"choices" => normalized_choices}
  end

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
