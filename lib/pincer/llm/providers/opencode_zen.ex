defmodule Pincer.LLM.Providers.OpencodeZen do
  @moduledoc """
  Adapter for Opencode Zen API.

  Particularities:
  - Standard OpenAI-compatible implementation (`https://api.opencode.ai/v1/chat/completions`).
  """
  @behaviour Pincer.LLM.Provider

  @impl true
  def chat_completion(messages, model, config, tools) do
    config = Map.put_new(config, :base_url, "https://opencode.ai/zen/v1/chat/completions")

    Pincer.LLM.Providers.OpenAICompat.chat_completion(messages, model, config, tools)
  end

  @impl true
  def stream_completion(messages, model, config, tools) do
    config = Map.put_new(config, :base_url, "https://opencode.ai/zen/v1/chat/completions")
    Pincer.LLM.Providers.OpenAICompat.stream_completion(messages, model, config, tools)
  end
end
