defmodule PincerOpenaiCompat do
  @moduledoc """
  OpenAI-compatible LLM provider adapter for the Pincer AI agent framework.

  Provides `Pincer.LLM.Providers.OpenAICompat` which implements the
  `PincerPorts.LLM.Provider` behaviour for any provider following the OpenAI API
  format (Groq, Together, vLLM, Ollama, OpenRouter, etc.).
  """
end
