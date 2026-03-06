defmodule Pincer.LLM.Providers.OpenAICompat do
  @moduledoc """
  A generic adapter for any LLM provider that strictly adopts the OpenAI API format.
  Includes Groq, Together, vLLM, Ollama, etc.
  """
  @behaviour Pincer.LLM.Provider

  require Logger

  @timeout 300_000
  @default_context_window 131_072
  @default_default_max_tokens 4_096
  @default_context_reserve_tokens 1_024
  @default_min_completion_tokens 256

  @impl true
  def chat_completion(messages, model, config, tools) do
    api_key = config[:api_key]
    base_url = config[:base_url]

    if is_nil(api_key) or api_key == "" or is_nil(base_url) or base_url == "" do
      Logger.warning("Incomplete provider configuration for #{__MODULE__}. Using MOCK mode.")
      {:ok, %{"role" => "assistant", "content" => "[MOCK] Hello! Configure your API Key."}, nil}
    else
      body = build_request_body(messages, model, tools, config, false)

      headers = config[:headers] || []

      case Req.post(base_url,
             json: body,
             auth: {:bearer, api_key},
             headers: headers,
             receive_timeout: @timeout,
             retry: :safe_transient
           ) do
        {:ok, response} ->
          handle_response(response)

        {:error, reason} ->
          Logger.error("LLM request error in OpenAICompat: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl true
  def stream_completion(messages, model, config, tools) do
    # OpenAI-compatible streaming path has shown provider-specific incompatibilities
    # in production (SSE framing and Req collectable mismatch). For stability,
    # fallback to single-shot completion and convert it into one synthetic stream chunk.
    case chat_completion(messages, model, config, tools) do
      {:ok, message, _usage} ->
        {:ok, message_to_stream_chunks(message)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec build_request_body([map()], String.t(), [map()], map(), boolean()) :: map()
  def build_request_body(messages, model, tools, config, stream?) do
    body = %{model: model, messages: messages}
    body = if stream?, do: Map.put(body, :stream, true), else: body
    body = if Enum.empty?(tools), do: body, else: Map.put(body, :tools, tools)
    inject_config_params(body, config, messages)
  end

  @doc false
  @spec message_to_stream_chunks(map()) :: [map()]
  def message_to_stream_chunks(message) when is_map(message) do
    content = extract_content(message)
    tool_calls = message["tool_calls"] || []

    delta = %{}
    delta = if content == "", do: delta, else: Map.put(delta, "content", content)

    delta =
      if is_list(tool_calls) and tool_calls != [] do
        Map.put(delta, "tool_calls", tool_calls_to_deltas(tool_calls))
      else
        delta
      end

    [%{"choices" => [%{"delta" => delta}]}]
  end

  defp inject_config_params(body, config, messages) do
    body =
      if is_number(config[:temperature]) do
        Map.put(body, :temperature, config[:temperature])
      else
        body
      end

    {token_key, safe_tokens} = completion_token_budget(messages, config)
    body = Map.put(body, token_key, safe_tokens)

    case config[:extra_body] do
      extra when is_map(extra) ->
        Map.merge(body, extra)

      _ ->
        body
    end
  end

  defp completion_token_budget(messages, config) do
    base_tokens =
      positive_integer(
        config[:max_completion_tokens] || config[:max_tokens] || config[:default_max_tokens],
        @default_default_max_tokens
      )

    context_window = positive_integer(config[:context_window], @default_context_window)

    reserve_tokens =
      positive_integer(config[:context_reserve_tokens], @default_context_reserve_tokens)

    min_completion_tokens =
      positive_integer(config[:min_completion_tokens], @default_min_completion_tokens)

    estimated_input_tokens = estimate_input_tokens(messages)
    available_tokens = max(1, context_window - estimated_input_tokens - reserve_tokens)

    clamped_tokens =
      base_tokens
      |> min(available_tokens)
      |> max(1)
      |> maybe_raise_to_minimum(available_tokens, min_completion_tokens)

    token_key =
      if is_map_key(config, :max_completion_tokens), do: :max_completion_tokens, else: :max_tokens

    if clamped_tokens < base_tokens do
      Logger.warning(
        "[LLM] Clamping #{token_key} from #{base_tokens} to #{clamped_tokens} (estimated_input=#{estimated_input_tokens}, context_window=#{context_window})."
      )
    end

    {token_key, clamped_tokens}
  end

  defp maybe_raise_to_minimum(current, available, min_completion)
       when available >= min_completion and current < min_completion,
       do: min_completion

  defp maybe_raise_to_minimum(current, _available, _min_completion), do: current

  defp estimate_input_tokens(messages) do
    messages
    |> Jason.encode!()
    |> byte_size()
    |> div(4)
  rescue
    _ -> 0
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp extract_content(%{"content" => content}) when is_binary(content), do: content
  defp extract_content(_), do: ""

  defp tool_calls_to_deltas(tool_calls) do
    tool_calls
    |> Enum.with_index()
    |> Enum.map(fn {tool_call, index} ->
      %{
        "index" => index,
        "id" => tool_call["id"],
        "function" => %{
          "name" => get_in(tool_call, ["function", "name"]) || "",
          "arguments" => get_in(tool_call, ["function", "arguments"]) || ""
        }
      }
    end)
  end

  defp handle_response(%Req.Response{status: 200, body: body}) do
    case body do
      %{"choices" => [%{"message" => message} | _]} ->
        usage = body["usage"]
        {:ok, message, usage}

      error_body when is_map(error_body) ->
        Logger.error("Unexpected response format: #{inspect(error_body)}")
        {:error, :unexpected_response_format}

      other ->
        Logger.error("Non-JSON response: #{inspect(other)}")
        {:error, :non_json_response}
    end
  end

  defp handle_response(%Req.Response{status: status, body: body} = response) do
    error_msg =
      if is_binary(body) and String.starts_with?(body, "<!") do
        "HTML Error Page (Start: #{String.slice(body, 0, 50)}...)"
      else
        inspect(body)
      end

    Logger.error("HTTP Error (#{status}): #{error_msg}")

    case retry_after_metadata(response) do
      meta when is_map(meta) and map_size(meta) > 0 ->
        {:error, {:http_error, status, error_msg, meta}}

      _ ->
        {:error, {:http_error, status, error_msg}}
    end
  end

  @impl true
  def list_models(config) do
    api_key = config[:api_key]
    base_url = config[:base_url]

    if is_nil(api_key) or api_key == "" or is_nil(base_url) or base_url == "" do
      {:ok, ["mock-model"]}
    else
      models_url = infer_models_url(base_url)
      headers = config[:headers] || []

      case Req.get(models_url,
             auth: {:bearer, api_key},
             headers: headers,
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
          Logger.warning("[LLM] Unexpected response listing models from #{models_url}: #{response.status}")
          {:error, :unexpected_response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp infer_models_url(chat_url) do
    cond do
      String.contains?(chat_url, "/chat/completions") ->
        String.replace(chat_url, "/chat/completions", "/models")

      String.ends_with?(chat_url, "/v1") ->
        chat_url <> "/models"

      true ->
        # Fallback assumption
        chat_url |> String.split("/") |> Enum.slice(0..-2//-1) |> Enum.join("/") |> Kernel.<>("/models")
    end
  end

  defp retry_after_metadata(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _] ->
        value = String.trim(value)

        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 ->
            %{retry_after_ms: seconds * 1000}

          _ ->
            %{retry_after: value}
        end

      _ ->
        nil
    end
  end
end
