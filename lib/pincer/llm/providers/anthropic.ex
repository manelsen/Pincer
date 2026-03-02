defmodule Pincer.LLM.Providers.Anthropic do
  @moduledoc """
  Adapter for Anthropic (Claude) API.

  Particularities:
  - Native Anthropic endpoint (`https://api.anthropic.com/v1/messages`).
  - System prompt is a top-level field, not inside `messages`.
  - Requires `x-api-key` and `anthropic-version`.
  - Messages must alternate strictly between `user` and `assistant`.
  """
  @behaviour Pincer.LLM.Provider

  require Logger

  @timeout 300_000

  @impl true
  def chat_completion(messages, model, config, tools) do
    api_key = config[:api_key]
    base_url = config[:base_url] || "https://api.anthropic.com/v1/messages"
    version = config[:anthropic_version] || "2023-06-01"

    if is_nil(api_key) or api_key == "" do
      Logger.warning("Incomplete provider configuration for Anthropic. Using MOCK mode.")

      {:ok,
       %{"role" => "assistant", "content" => "[MOCK] Hello! Configure your Anthropic API Key."}}
    else
      # 1. Extract System prompt (Anthropic requires it at the root)
      {system_messages, chat_messages} =
        Enum.split_with(messages, fn %{"role" => r} -> r == "system" end)

      system_prompt = Enum.map(system_messages, & &1["content"]) |> Enum.join("\n\n")

      # 2. Format Body
      body = %{
        model: model,
        # Anthropic requires max_tokens
        max_tokens: config[:max_tokens] || 4096,
        messages: chat_messages
      }

      body = if system_prompt != "", do: Map.put(body, :system, system_prompt), else: body

      # 3. Format Tools (Anthropic uses a different schema, but we attempt base translation here
      # For a production-ready system, full JSON schema translation OpenAI -> Anthropic is needed)
      body =
        if Enum.empty?(tools) do
          body
        else
          anthropic_tools =
            Enum.map(tools, fn %{"function" => f} ->
              %{
                name: f["name"],
                description: f["description"] || "",
                input_schema: f["parameters"] || %{type: "object", properties: %{}}
              }
            end)

          Map.put(body, :tools, anthropic_tools)
        end

      body =
        if is_map_key(config, :temperature),
          do: Map.put(body, :temperature, config[:temperature]),
          else: body

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", version},
        {"content-type", "application/json"}
      ]

      case Req.post(base_url,
             json: body,
             headers: headers,
             receive_timeout: @timeout,
             retry: :safe_transient
           ) do
        {:ok, response} ->
          handle_response(response)

        {:error, reason} ->
          Logger.error("LLM request error in Anthropic adapter: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl true
  def stream_completion(messages, model, config, tools) do
    # Anthropic streaming is not wired yet in this adapter.
    # Fallback to single-shot completion and emit one stream chunk.
    case chat_completion(messages, model, config, tools) do
      {:ok, %{"content" => content}} ->
        {:ok, [%{"choices" => [%{"delta" => %{"content" => content || ""}}]}]}

      {:ok, _other} ->
        {:ok, [%{"choices" => [%{"delta" => %{"content" => ""}}]}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_response(%Req.Response{status: 200, body: body}) do
    # Translate Anthropic response back to OpenAI Message format
    content_blocks = body["content"] || []

    text_content =
      content_blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("")

    tool_uses =
      content_blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn tu ->
        %{
          "id" => tu["id"],
          "type" => "function",
          "function" => %{
            "name" => tu["name"],
            "arguments" => Jason.encode!(tu["input"])
          }
        }
      end)

    message = %{"role" => "assistant", "content" => text_content}

    message =
      if Enum.empty?(tool_uses), do: message, else: Map.put(message, "tool_calls", tool_uses)

    {:ok, message}
  end

  defp handle_response(%Req.Response{status: status, body: body}) do
    error_msg = inspect(body)
    Logger.error("HTTP Error from Anthropic (#{status}): #{error_msg}")
    {:error, {:http_error, status, error_msg}}
  end
end
