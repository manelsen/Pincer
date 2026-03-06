defmodule Pincer.LLM.Providers.Groq do
  @moduledoc """
  Adapter for Groq API.

  Particularities:
  - High-performance inference.
  - OpenAI-compatible endpoints (`https://api.groq.com/openai/v1/chat/completions`).
  """
  @behaviour Pincer.LLM.Provider
  alias Pincer.LLM.Providers.OpenAICompat

  @impl true
  def chat_completion(messages, model, config, tools) do
    config = Map.put_new(config, :base_url, "https://api.groq.com/openai/v1/chat/completions")
    OpenAICompat.chat_completion(messages, model, config, tools)
  end

  @impl true
  def stream_completion(messages, model, config, tools) do
    config = Map.put_new(config, :base_url, "https://api.groq.com/openai/v1/chat/completions")
    OpenAICompat.stream_completion(messages, model, config, tools)
  end

  @impl true
  def list_models(config) do
    config = Map.put_new(config, :base_url, "https://api.groq.com/openai/v1/chat/completions")
    OpenAICompat.list_models(config)
  end
end
