defmodule Pincer.LLM.Providers.Qwen do
  @moduledoc """
  Adapter for Alibaba Cloud DashScope (Qwen) API.

  Particularities:
  - Strongly compatible with OpenAI when using the `/compatible-mode/v1` endpoint.
  - Supports `enable_thinking` field for Qwen3 and Qwen-Plus.
  - Supports specific `stream_options`.
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

  defp normalize_config(config) do
    config =
      config
      |> Map.put_new(
        :base_url,
        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
      )

    if config[:enable_thinking] do
      Map.put(config, :extra_body, %{"enable_thinking" => true})
    else
      config
    end
  end
end
