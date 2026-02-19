defmodule Pincer.Models do
  @moduledoc """
  Centraliza a configuração e gerenciamento de modelos LLM.
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
  Retorna o mapa completo de configuração de modelos.
  """
  def all, do: @models_config

  @doc """
  Retorna a lista de provedores disponíveis.
  """
  def providers, do: Map.keys(@models_config)

  @doc """
  Retorna os modelos para um provedor específico.
  """
  def for_provider(provider) when is_binary(provider) do
    Map.get(@models_config, provider, [])
  end

  @doc """
  Retorna um mapa de provedores para exibição (capitalizado).
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
  Verifica se um provedor existe.
  """
  def valid_provider?(provider) do
    Map.has_key?(@models_config, provider)
  end

  @doc """
  Verifica se um modelo existe para um provedor.
  """
  def valid_model?(provider, model_id) do
    provider
    |> for_provider()
    |> Enum.any?(fn {_, id} -> id == model_id end)
  end
end
