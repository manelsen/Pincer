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

    case OpenAICompat.list_models(config) do
      {:ok, models} ->
        tagged_models =
          models
          |> Enum.map(fn m ->
            # Groq doesn't always tag free models in the ID, but often includes 
            # them in a specific tier or name. We check for 'free' or small models often used as free.
            is_free = String.contains?(String.downcase(m), "free") or 
                      String.contains?(String.downcase(m), "versa") # 'versatile' is often the free tier
            {m, is_free}
          end)
          |> Enum.sort_by(fn {_, free} -> not free end)
          |> Enum.map(fn {id, free} ->
            if free, do: "#{id} (FREE)", else: id
          end)

        {:ok, tagged_models}

      error ->
        error
    end
  end

  @impl true
  def transcribe_audio(_file_path, _model, _config), do: {:error, :not_implemented}
end
