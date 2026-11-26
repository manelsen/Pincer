defmodule Pincer.LLM.ModelCache do
  @moduledoc """
  Provider catalog lookup and 1-hour ETS-backed model list cache.

  Merges `config.yaml` (`:pincer, :llm`) over `:pincer, :llm_providers` for
  provider/model selection and fingerprints each provider's effective config
  so cache entries invalidate automatically when configuration changes.
  """

  alias Pincer.Core.AuthProfiles
  alias Pincer.Core.Models.Registry, as: ModelRegistry
  alias Pincer.LLM.CooldownRouting
  alias Pincer.Utils.ETSHelper

  @cache_table :pincer_llm_cache
  @cache_ttl_seconds 3600

  @doc """
  Returns all configured LLM providers in stable order from the merged registry.
  """
  @spec list_providers() :: [%{id: String.t(), name: String.t()}]
  def list_providers do
    ModelRegistry.list_providers(model_selection_registry())
  end

  @doc """
  Returns the raw configuration map for `provider_id`, or `nil` when absent.
  """
  @spec provider_config(String.t()) :: map() | nil
  def provider_config(provider_id) do
    registry = CooldownRouting.provider_registry()
    registry[provider_id]
  end

  @doc """
  Returns available models for `provider_id`, using a 1-hour ETS cache keyed
  by configuration fingerprint.
  """
  @spec list_models(String.t()) :: [String.t()]
  def list_models(provider_id) do
    cache_key = {:models, provider_id, config_fingerprint(provider_id)}

    case get_cached_models(cache_key) do
      {:ok, models} ->
        models

      :miss ->
        models = fetch_models_from_provider(provider_id)
        put_cached_models(cache_key, models)
        models
    end
  end

  @doc """
  Returns the merged provider registry with `:pincer, :llm` taking precedence
  over `:pincer, :llm_providers`.
  """
  @spec model_selection_registry() :: map()
  def model_selection_registry do
    llm_registry = llm_config_registry()
    providers_registry = Application.get_env(:pincer, :llm_providers, %{}) || %{}
    Map.merge(providers_registry, llm_registry)
  end

  @doc """
  Computes a fingerprint for `provider_id`'s effective configuration so cached
  model lists are scoped to the exact configuration that produced them.
  """
  @spec config_fingerprint(String.t()) :: integer()
  def config_fingerprint(provider_id) do
    :erlang.phash2({provider_config(provider_id), model_selection_registry()})
  end

  defp fetch_models_from_provider("mock"),
    do: ModelRegistry.list_models("mock", model_selection_registry())

  defp fetch_models_from_provider(provider_id) do
    config = provider_config(provider_id)
    do_fetch_models(provider_id, config)
  end

  defp do_fetch_models(provider_id, nil),
    do: ModelRegistry.list_models(provider_id, model_selection_registry())

  defp do_fetch_models(provider_id, config) do
    adapter = config[:adapter]

    with {:ok, auth_selection} <-
           AuthProfiles.resolve(provider_id, config, requested_profile: nil),
         {:ok, models} when is_list(models) and models != [] <-
           apply(adapter, :list_models, [auth_selection.config]) do
      models
    else
      _ ->
        ModelRegistry.list_models(provider_id, model_selection_registry())
    end
  end

  defp get_cached_models(key) do
    ensure_cache_table()

    case :ets.lookup(@cache_table, key) do
      [{^key, models, expiry}] ->
        if System.system_time(:second) < expiry do
          {:ok, models}
        else
          :ets.delete(@cache_table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp put_cached_models(key, models) do
    ensure_cache_table()
    expiry = System.system_time(:second) + @cache_ttl_seconds
    :ets.insert(@cache_table, {key, models, expiry})
  end

  defp ensure_cache_table do
    _ =
      ETSHelper.ensure_named_table(@cache_table,
        options: [:named_table, :public, :set, read_concurrency: true]
      )
  end

  defp llm_config_registry do
    case Application.get_env(:pincer, :llm, %{}) do
      llm when is_map(llm) ->
        Enum.reduce(llm, %{}, fn {provider_id, config}, acc ->
          normalized_provider = normalize_provider_id(provider_id)

          if normalized_provider in ["", "provider"] or not is_map(config) do
            acc
          else
            Map.put(acc, normalized_provider, config)
          end
        end)

      _ ->
        %{}
    end
  end

  defp normalize_provider_id(provider_id) when is_atom(provider_id),
    do: provider_id |> Atom.to_string() |> String.trim()

  defp normalize_provider_id(provider_id) when is_binary(provider_id),
    do: String.trim(provider_id)

  defp normalize_provider_id(provider_id),
    do: provider_id |> to_string() |> String.trim()
end
