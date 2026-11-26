defmodule Pincer.LLM.Providers.DeepSeek do
  @moduledoc """
  Adapter for DeepSeek API.

  Particularities:
  - OpenAI-compatible endpoints (`https://api.deepseek.com/chat/completions`).
  - Supports `deepseek-chat` and `deepseek-reasoner`.
  """
  use Pincer.LLM.Providers.OpenAICompat,
    base_url: "https://api.deepseek.com/chat/completions"
end
