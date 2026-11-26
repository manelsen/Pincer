defmodule Pincer.LLM.Providers.Zhipu do
  @moduledoc """
  Adapter for Z.AI (Zhipu GLM) API.

  Particularities:
  - Strongly compatible with OpenAI, but injects GLM-specific fields.
  - Supports `max_completion_tokens` instead of `max_tokens` (since GLM-4).
  - Supports thinking mode toggle.
  """
  use Pincer.LLM.Providers.OpenAICompat,
    base_url: "https://open.bigmodel.cn/api/paas/v4/chat/completions"

  # Zhipu GLM API uses the same schema, so we leverage the base compat adapter
  # and only inject provider-specific settings here.
  @doc false
  def normalize_config(config) do
    config = super(config)

    if config[:thinking] do
      # Some Zhipu SDK models accept raw parameter injections for CoT.
      Map.put(config, :extra_body, %{"thinking" => true})
    else
      config
    end
  end
end
