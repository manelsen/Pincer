defmodule Pincer.LLM.Providers.Google do
  @moduledoc """
  Adapter for Google Gemini API (Google AI Studio).

  Particularities:
  - Uses `generateContent` endpoints.
  - Requires translating OpenAI `{role: "user", content: "..."}` to Gemini `{role: "user", parts: [{text: "..."}]}`.
  - System instruction is passed via a separate field.
  """
  @behaviour Pincer.LLM.Provider

  require Logger

  @timeout 300_000

  @impl true
  def chat_completion(messages, model, config, tools) do
    api_key = config[:api_key]

    # Example: https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-pro:generateContent
    base_url =
      config[:base_url] ||
        "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}"

    if is_nil(api_key) or api_key == "" do
      Logger.warning("Incomplete provider configuration for Google. Using MOCK mode.")

      {:ok, %{"role" => "assistant", "content" => "[MOCK] Hello! Configure your Google API Key."},
       nil}
    else
      {system_msgs, chat_msgs} = Enum.split_with(messages, fn m -> m["role"] == "system" end)

      # Translate OpenAI/Pincer chat format to Gemini contents format.
      # content may be a plain String or a list of parts (multimodal).
      gemini_contents =
        Enum.map(chat_msgs, fn msg ->
          role = if msg["role"] == "assistant", do: "model", else: msg["role"]
          parts = translate_content_to_parts(msg["content"])
          %{"role" => role, "parts" => parts}
        end)

      body = %{
        contents: gemini_contents
      }

      # Inject System Prompt
      body =
        if not Enum.empty?(system_msgs) do
          sys_text = Enum.map(system_msgs, & &1["content"]) |> Enum.join("\n")
          Map.put(body, :systemInstruction, %{parts: [%{text: sys_text}]})
        else
          body
        end

      # For production, implement Tool mapping here
      _tools_ignored_for_now = tools

      case Req.post(base_url,
             json: body,
             receive_timeout: @timeout,
             retry: :safe_transient
           ) do
        {:ok, response} ->
          handle_response(response)

        {:error, reason} ->
          Logger.error("LLM request error in Google adapter: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl true
  def stream_completion(messages, model, config, tools) do
    # Native Gemini streaming is not wired yet in this adapter.
    # Fallback to single-shot completion and emit one stream chunk.
    case chat_completion(messages, model, config, tools) do
      {:ok, %{"content" => content}, _usage} ->
        {:ok, [%{"choices" => [%{"delta" => %{"content" => content || ""}}]}]}

      {:ok, _other, _usage} ->
        {:ok, [%{"choices" => [%{"delta" => %{"content" => ""}}]}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Converts a Pincer message content (String or list of parts) to Gemini parts.
  @doc false
  def translate_content_to_parts(nil), do: [%{"text" => ""}]

  def translate_content_to_parts(content) when is_binary(content) do
    [%{"text" => content}]
  end

  def translate_content_to_parts(parts) when is_list(parts) do
    Enum.flat_map(parts, fn
      %{"type" => "text", "text" => text} ->
        [%{"text" => text}]

      %{"type" => "inline_data", "mime_type" => mime, "data" => base64} ->
        # Gemini inlineData: base64-encoded file content embedded directly in the request.
        [%{"inlineData" => %{"mimeType" => mime, "data" => base64}}]

      %{"type" => "attachment_ref"} ->
        # Should have been resolved by the Executor before reaching here.
        # If it arrives unresolved, log and skip.
        []

      _ ->
        []
    end)
  end

  defp handle_response(%Req.Response{status: 200, body: body}) do
    # Translate Google response back to standard format

    first_candidate = get_in(body, ["candidates", Access.at(0)])

    if first_candidate do
      parts = get_in(first_candidate, ["content", "parts"]) || []

      text =
        parts
        |> Enum.filter(&is_map_key(&1, "text"))
        |> Enum.map(& &1["text"])
        |> Enum.join("")

      {:ok, %{"role" => "assistant", "content" => text}, nil}
    else
      Logger.error("Empty candidates in Gemini response: #{inspect(body)}")
      {:error, :empty_response}
    end
  end

  @impl true
  def list_models(config) do
    api_key = config[:api_key]

    if is_nil(api_key) or api_key == "" do
      {:ok, ["gemini-1.5-flash"]}
    else
      url = "https://generativelanguage.googleapis.com/v1beta/models"

      case Req.get(url, params: [key: api_key], receive_timeout: 10_000) do
        {:ok, %{status: 200, body: %{"models" => models}}} when is_list(models) ->
          # Clean prefix 'models/' and filter for those supporting generateContent
          list =
            models
            |> Enum.filter(fn m ->
              "generateContent" in (m["supportedGenerationMethods"] || [])
            end)
            |> Enum.map(fn m -> String.replace(m["name"] || "", "models/", "") end)
            |> Enum.reject(&(&1 == ""))
            |> Enum.sort()

          {:ok, list}

        _ ->
          {:error, :fetch_failed}
      end
    end
  end

  @impl true
  def transcribe_audio(_file_path, _model, _config), do: {:error, :not_implemented}
  @impl true
  def generate_embedding(_text, _model, _config), do: {:error, :not_implemented}
end
