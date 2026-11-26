defmodule Pincer.LLM.Providers.Moonshot do
  @moduledoc """
  Adapter for Moonshot (Kimi) API.

  Particularities:
  - Strong OpenAI compatibility (`https://api.moonshot.ai/v1/chat/completions`).
  - Limits `temperature` closely to `[0, 1]` rather than OpenAI's default.
  - Requires `chat_template_kwargs: {"thinking": False}` for Kimi K2.5 Instant Mode.
  """
  use Pincer.LLM.Providers.OpenAICompat,
    base_url: "https://api.moonshot.ai/v1/chat/completions"

  @doc false
  def normalize_config(config) do
    config = super(config)

    # Moonshot prohibits `temperature=0` with `n>1`, and strongly advises
    # clamping temperature. We enforce it here if present in config.
    config =
      if is_map_key(config, :temperature) do
        temp = min(max(config[:temperature], 0.0), 1.0)
        Map.put(config, :temperature, temp)
      else
        config
      end

    if config[:thinking] == false do
      Map.put(config, :extra_body, %{"chat_template_kwargs" => %{"thinking" => false}})
    else
      config
    end
  end
end
