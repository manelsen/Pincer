defmodule Pincer.LLM.Providers.OpenRouter do
  @moduledoc """
  Adapter for OpenRouter API.

  Particularities:
  - Strongly compatible with OpenAI (`https://openrouter.ai/api/v1/chat/completions`).
  - Requires `HTTP-Referer` and `X-Title` headers for application ranking.
  """
  @behaviour Pincer.LLM.Provider

  @impl true
  def chat_completion(messages, model, config, tools) do
    config = normalize_config(config)
    Pincer.LLM.Providers.OpenAICompat.chat_completion(messages, model, config, tools)
  end

  @impl true
  def stream_completion(messages, model, config, tools) do
    config = normalize_config(config)
    Pincer.LLM.Providers.OpenAICompat.stream_completion(messages, model, config, tools)
  end

  @impl true
  def list_models(config) do
    # OpenRouter has a public metadata API for models
    url = "https://openrouter.ai/api/v1/models"
    headers = [{"HTTP-Referer", "https://github.com/Pincer/pincer"}, {"X-Title", "Pincer"}]

    case Req.get(url, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        # Detect free models by checking pricing
        models =
          data
          |> Enum.map(fn m ->
            id = m["id"]
            pricing = m["pricing"] || %{}
            is_free = pricing["prompt"] == "0" and pricing["completion"] == "0"
            {id, is_free}
          end)
          |> Enum.sort_by(fn {_, free} -> not free end) # Free first
          |> Enum.map(fn {id, free} ->
            if free, do: "#{id} (FREE)", else: id
          end)

        {:ok, models}

      _ ->
        # Fallback to generic if metadata fails
        Pincer.LLM.Providers.OpenAICompat.list_models(normalize_config(config))
    end
  end

  @impl true
  def transcribe_audio(_file_path, _model, _config), do: {:error, :not_implemented}

  @impl true
  def generate_embedding(text, model, config) do
    config = normalize_config(config)
    Pincer.LLM.Providers.OpenAICompat.generate_embedding(text, model, config)
  end

  defp normalize_config(config) do
    config = Map.put_new(config, :base_url, "https://openrouter.ai/api/v1/chat/completions")

    # Inject application headers required by OpenRouter
    existing_headers = config[:headers] || []

    openrouter_headers = [
      {"HTTP-Referer", "https://github.com/Pincer/pincer"},
      {"X-Title", "Pincer"}
    ]

    Map.put(config, :headers, existing_headers ++ openrouter_headers)
  end
end
