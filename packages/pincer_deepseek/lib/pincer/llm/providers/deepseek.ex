defmodule Pincer.LLM.Providers.DeepSeek do
  @moduledoc """
  Adapter for DeepSeek API.

  Particularities:
  - OpenAI-compatible endpoints (`https://api.deepseek.com/chat/completions`).
  - Supports V4 aliases such as `deepseek-v4-flash` and `deepseek-v4-pro`.
  """
  use Pincer.LLM.Providers.OpenAICompat,
    base_url: "https://api.deepseek.com/chat/completions"
end
