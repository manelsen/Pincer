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

  @impl true
  def list_models(config) do
    config = Map.put_new(config, :base_url, "https://opencode.ai/zen/v1/chat/completions")

    case Pincer.LLM.Providers.OpenAICompat.list_models(config) do
      {:ok, models} ->
        tagged_models =
          models
          |> Enum.map(fn m ->
            is_free = String.contains?(String.downcase(m), "free")
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
end
