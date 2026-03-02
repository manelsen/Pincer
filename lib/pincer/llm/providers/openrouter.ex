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
