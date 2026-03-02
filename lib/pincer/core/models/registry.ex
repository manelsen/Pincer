defmodule Pincer.Core.Models.Registry do
  @moduledoc """
  Read-only catalog of LLM providers and models.

  This module is core-first: channel and provider adapters consume the same
  normalized registry view. It accepts runtime config maps and normalizes:

  - provider listing for UI (`list_providers/1`)
  - model listing per provider (`list_models/2`)
  - alias resolution (`resolve_model/3`)
  """

  @type provider_id :: String.t()
  @type registry_map :: map()

  @doc """
  Lists providers in stable order (`id` ascending).
  """
  @spec list_providers(registry_map() | nil) :: [%{id: provider_id(), name: String.t()}]
  def list_providers(registry \\ nil) do
    normalized_registry = effective_registry(registry)

    normalized_registry
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn id ->
      config = Map.get(normalized_registry, id, %{})
      %{id: id, name: provider_name(id, config)}
    end)
  end

  @doc """
  Lists available models for a provider.

  Merges `default_model` + `models` (or `model_list`) with dedupe and invalid
  value filtering.
  """
  @spec list_models(provider_id(), registry_map() | nil) :: [String.t()]
  def list_models(provider_id, registry \\ nil) do
    registry = effective_registry(registry)
    provider_id = normalize_string(provider_id)

    case Map.get(registry, provider_id) do
      nil ->
        []

      config ->
        default_model = normalize_model(extract_field(config, "default_model"))
        configured_models = model_entries(config)

        [default_model | configured_models]
        |> Enum.reject(&(&1 == ""))
        |> uniq_preserve_order()
    end
  end

  @doc """
  Resolves a model id or alias for a provider.
  """
  @spec resolve_model(provider_id(), String.t(), registry_map() | nil) ::
          {:ok, String.t()} | {:error, :unknown_provider | :unknown_model}
  def resolve_model(provider_id, model_or_alias, registry \\ nil) do
    registry = effective_registry(registry)
    provider_id = normalize_string(provider_id)

    case Map.get(registry, provider_id) do
      nil ->
        {:error, :unknown_provider}

      config ->
        aliases = model_aliases(config)
        requested = normalize_model(model_or_alias)
        resolved = Map.get(aliases, requested, requested)

        if resolved in list_models(provider_id, registry) do
          {:ok, resolved}
        else
          {:error, :unknown_model}
        end
    end
  end

  defp effective_registry(nil),
    do: effective_registry(Application.get_env(:pincer, :llm_providers, %{}))

  defp effective_registry(registry) when is_map(registry) do
    Enum.reduce(registry, %{}, fn {provider, config}, acc ->
      provider_id = normalize_string(provider)

      if provider_id == "" or not is_map(config) do
        acc
      else
        Map.put(acc, provider_id, config)
      end
    end)
  end

  defp effective_registry(_), do: %{}

  defp provider_name(provider_id, config) do
    explicit = normalize_string(extract_field(config, "name"))

    if explicit != "" do
      explicit
    else
      provider_id
      |> String.split(~r/[_-]+/, trim: true)
      |> Enum.map(&String.capitalize/1)
      |> Enum.join(" ")
      |> normalize_string()
    end
  end

  defp model_entries(config) do
    models = extract_field(config, "models") || extract_field(config, "model_list")

    case models do
      list when is_list(list) ->
        Enum.map(list, &normalize_model_entry/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp model_aliases(config) do
    aliases = extract_field(config, "model_aliases") || extract_field(config, "aliases") || %{}

    if is_map(aliases) do
      Enum.reduce(aliases, %{}, fn {alias_name, model_id}, acc ->
        key = normalize_string(alias_name)
        value = normalize_model(model_id)

        if key == "" or value == "" do
          acc
        else
          Map.put(acc, key, value)
        end
      end)
    else
      %{}
    end
  end

  defp normalize_model_entry(entry) when is_binary(entry), do: normalize_model(entry)
  defp normalize_model_entry(nil), do: ""

  defp normalize_model_entry(entry) when is_atom(entry),
    do: entry |> Atom.to_string() |> normalize_model()

  defp normalize_model_entry({_label, id}) when is_binary(id),
    do: normalize_model(id)

  defp normalize_model_entry(%{} = entry) do
    normalize_model(extract_field(entry, "id") || extract_field(entry, "model"))
  end

  defp normalize_model_entry(_), do: ""

  defp uniq_preserve_order(list) do
    {acc_rev, _seen} =
      Enum.reduce(list, {[], MapSet.new()}, fn item, {items, seen} ->
        if MapSet.member?(seen, item) do
          {items, seen}
        else
          {[item | items], MapSet.put(seen, item)}
        end
      end)

    Enum.reverse(acc_rev)
  end

  defp normalize_model(value), do: normalize_string(value)

  defp normalize_string(nil), do: ""

  defp normalize_string(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp extract_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom_key, value} when is_atom(atom_key) ->
          if Atom.to_string(atom_key) == key, do: value, else: nil

        _ ->
          nil
      end)
  end

  defp extract_field(_, _), do: nil
end
