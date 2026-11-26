defmodule Pincer.LLM.Providers.Qwen do
  @moduledoc """
  Adapter for Alibaba Cloud DashScope (Qwen) API.

  Particularities:
  - Strongly compatible with OpenAI when using the `/compatible-mode/v1` endpoint.
  - Supports `enable_thinking` field for Qwen3 and Qwen-Plus.
  - Supports specific `stream_options`.
  """
  use Pincer.LLM.Providers.OpenAICompat,
    base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"

  @doc false
  def normalize_config(config) do
    config = super(config)

    if config[:enable_thinking] do
      Map.put(config, :extra_body, %{"enable_thinking" => true})
    else
      config
    end
  end
end
