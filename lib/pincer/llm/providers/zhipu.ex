defmodule Pincer.LLM.Providers.Zhipu do
  @moduledoc """
  Adapter for Z.AI (Zhipu GLM) API.

  Particularities:
  - Strongly compatible with OpenAI, but injects GLM-specific fields.
  - Supports `max_completion_tokens` instead of `max_tokens` (since GLM-4).
  - Supports thinking mode toggle.
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
    config = normalize_config(config)
    Pincer.LLM.Providers.OpenAICompat.list_models(config)
  end

  @impl true
  def transcribe_audio(_file_path, _model, _config), do: {:error, :not_implemented}
  @impl true
  def generate_embedding(_text, _model, _config), do: {:error, :not_implemented}

  # Zhipu GLM API uses the same schema, so we leverage the base compat adapter
  # and only inject provider-specific settings here.
  defp normalize_config(config) do
    config =
      config
      |> Map.put_new(:base_url, "https://open.bigmodel.cn/api/paas/v4/chat/completions")

    if config[:thinking] do
      # Some Zhipu SDK models accept raw parameter injections for CoT.
      Map.put(config, :extra_body, %{"thinking" => true})
    else
      config
    end
  end
end
