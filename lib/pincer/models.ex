defmodule Pincer.Models do
  @moduledoc """
  Centralizes LLM model configuration and management.
  """

  @models_config %{
    "opencode_zen" => [
      {"Kimi 2.5 Free", "kimi-k2.5-free"},
      {"GLM 5 Free", "glm-5-free"},
      {"MiniMax 2.5 Free", "minimax-m2.5-free"}
    ],
    "openrouter" => [
      {"Stepfun 3.5 Flash", "stepfun/step-3.5-flash:free"},
      {"Aurora Alpha", "openrouter/aurora-alpha"}
    ]
  }

  @doc """
  Returns the complete model configuration map.
  """
  def all, do: @models_config

  @doc """
  Returns the list of available providers.
  """
  def providers, do: Map.keys(@models_config)

  @doc """
  Returns models for a specific provider.
  """
  def for_provider(provider) when is_binary(provider) do
    Map.get(@models_config, provider, [])
  end

  @doc """
  Returns a map of providers for display (capitalized).
  """
  def providers_for_display do
    @models_config
    |> Map.keys()
    |> Enum.map(fn provider ->
      display_name =
        provider
        |> String.replace("_", " ")
        |> String.capitalize()

      {display_name, provider}
    end)
  end

  @doc """
  Checks if a provider exists.
  """
  def valid_provider?(provider) do
    Map.has_key?(@models_config, provider)
  end

  @doc """
  Checks if a model exists for a provider.
  """
  def valid_model?(provider, model_id) do
    provider
    |> for_provider()
    |> Enum.any?(fn {_, id} -> id == model_id end)
  end
end
