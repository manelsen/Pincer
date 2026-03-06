defmodule Pincer.LLM.Providers.DeepSeek do
  @moduledoc """
  Adapter for DeepSeek API.

  Particularities:
  - OpenAI-compatible endpoints (`https://api.deepseek.com/chat/completions`).
  - Supports `deepseek-chat` and `deepseek-reasoner`.
  """
  @behaviour Pincer.LLM.Provider

  @impl true
  def chat_completion(messages, model, config, tools) do
    config = Map.put_new(config, :base_url, "https://api.deepseek.com/chat/completions")

    # DeepSeek drops the /v1/ sometimes or requires standard formats.
    # The default compatibility adapter works perfectly for DeepSeek.
    Pincer.LLM.Providers.OpenAICompat.chat_completion(messages, model, config, tools)
  end

  @impl true
  def stream_completion(messages, model, config, tools) do
    config = Map.put_new(config, :base_url, "https://api.deepseek.com/chat/completions")
    Pincer.LLM.Providers.OpenAICompat.stream_completion(messages, model, config, tools)
  end

  @impl true
  def list_models(config) do
    config = Map.put_new(config, :base_url, "https://api.deepseek.com/chat/completions")
    Pincer.LLM.Providers.OpenAICompat.list_models(config)
  end
end
