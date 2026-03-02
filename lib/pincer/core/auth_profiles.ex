defmodule Pincer.Core.AuthProfiles do
  @moduledoc """
  Credential profile selection and rotation for LLM providers.

  Supports:
  - ordered profile precedence
  - explicit profile preference
  - cooldown-aware profile rotation
  """

  alias Pincer.Core.ErrorClass

  @table :pincer_auth_profile_cooldown
  @default_profile "default"

  @default_durations %{
    http_401: 120_000,
    http_403: 120_000
  }

  @type selection :: %{
          profile: String.t() | nil,
          api_key: String.t() | nil,
          config: map()
        }

  @spec resolve(String.t(), map(), keyword()) ::
          {:ok, selection()} | {:error, :missing_credentials | :all_profiles_cooling_down}
  def resolve(provider_id, provider_config, opts \\ [])

  def resolve(provider_id, provider_config, opts)
      when is_binary(provider_id) and is_map(provider_config) do
    env_fetcher = Keyword.get(opts, :env_fetcher, &System.get_env/1)
    requested_profile = normalize_profile_name(Keyword.get(opts, :requested_profile))
    profiles = provider_profiles(provider_config) |> prioritize_profile(requested_profile)

    cond do
      profiles == [] and declares_auth_chain?(provider_config) ->
        {:error, :missing_credentials}

      profiles == [] ->
        {:ok, legacy_selection(provider_config)}

      true ->
        evaluated =
          Enum.map(profiles, fn profile ->
            api_key = env_fetcher.(profile.env_key)

            %{
              profile: profile,
              api_key: normalize_api_key(api_key),
              cooling: cooling_down?(provider_id, profile.name)
            }
          end)

        case Enum.find(evaluated, fn item -> present?(item.api_key) and not item.cooling end) do
          %{profile: profile, api_key: api_key} ->
            config =
              provider_config
              |> Map.put(:api_key, api_key)
              |> Map.put(:auth_profile, profile.name)
              |> Map.put(:auth_env_key, profile.env_key)

            {:ok, %{profile: profile.name, api_key: api_key, config: config}}

          nil ->
            cond do
              Enum.any?(evaluated, &present?(&1.api_key)) ->
                {:error, :all_profiles_cooling_down}

              true ->
                {:error, :missing_credentials}
            end
        end
    end
  end

  def resolve(_provider_id, _provider_config, _opts), do: {:error, :missing_credentials}

  @spec cooldown_profile(String.t(), String.t(), term(), keyword()) :: :ok
  def cooldown_profile(provider_id, profile_name, reason_or_class, opts \\ [])

  def cooldown_profile(provider_id, profile_name, reason_or_class, opts)
      when is_binary(provider_id) and provider_id != "" and is_binary(profile_name) and
             profile_name != "" do
    class = classify(reason_or_class)
    duration_ms = duration_ms(class, opts)

    if duration_ms > 0 do
      ensure_table()
      key = cooldown_key(provider_id, profile_name)
      now = now_ms()
      expires_at = now + duration_ms

      case :ets.lookup(@table, key) do
        [{^key, existing_expires_at, _existing_class}] when existing_expires_at >= expires_at ->
          :ok

        _ ->
          :ets.insert(@table, {key, expires_at, class})
          :ok
      end
    else
      :ok
    end
  end

  def cooldown_profile(_provider_id, _profile_name, _reason_or_class, _opts), do: :ok

  @spec cooling_down?(String.t(), String.t()) :: boolean()
  def cooling_down?(provider_id, profile_name)
      when is_binary(provider_id) and provider_id != "" and is_binary(profile_name) and
             profile_name != "" do
    ensure_table()
    key = cooldown_key(provider_id, profile_name)

    case :ets.lookup(@table, key) do
      [{^key, expires_at, _class}] ->
        if expires_at > now_ms() do
          true
        else
          :ets.delete(@table, key)
          false
        end

      _ ->
        false
    end
  end

  def cooling_down?(_provider_id, _profile_name), do: false

  @spec clear_profile(String.t(), String.t()) :: :ok
  def clear_profile(provider_id, profile_name)
      when is_binary(provider_id) and provider_id != "" and is_binary(profile_name) and
             profile_name != "" do
    ensure_table()
    :ets.delete(@table, cooldown_key(provider_id, profile_name))
    :ok
  end

  def clear_profile(_provider_id, _profile_name), do: :ok

  @doc false
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp provider_profiles(config) when is_map(config) do
    profiles = read_field(config, :auth_profiles)

    cond do
      is_list(profiles) and profiles != [] ->
        profiles
        |> Enum.map(&normalize_profile/1)
        |> Enum.reject(&is_nil/1)

      present?(read_field(config, :env_key)) ->
        [%{name: @default_profile, env_key: to_string(read_field(config, :env_key))}]

      true ->
        []
    end
  end

  defp declares_auth_chain?(config) when is_map(config) do
    has_field?(config, :auth_profiles) or has_field?(config, :env_key)
  end

  defp legacy_selection(provider_config) do
    api_key = normalize_api_key(read_field(provider_config, :api_key))

    %{
      profile: nil,
      api_key: api_key,
      config: maybe_put_api_key(provider_config, api_key)
    }
  end

  defp maybe_put_api_key(config, api_key) when is_binary(api_key),
    do: Map.put(config, :api_key, api_key)

  defp maybe_put_api_key(config, _api_key), do: config

  defp normalize_profile(%{} = profile) do
    name =
      profile
      |> read_field(:name)
      |> normalize_profile_name()

    env_key =
      profile
      |> read_field(:env_key)
      |> normalize_env_key()

    if present?(name) and present?(env_key) do
      %{name: name, env_key: env_key}
    else
      nil
    end
  end

  defp normalize_profile(_), do: nil

  defp prioritize_profile(profiles, nil), do: profiles

  defp prioritize_profile(profiles, requested_profile) do
    {selected, remaining} =
      Enum.split_with(profiles, fn profile -> profile.name == requested_profile end)

    selected ++ remaining
  end

  defp normalize_profile_name(nil), do: nil

  defp normalize_profile_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp normalize_env_key(nil), do: nil

  defp normalize_env_key(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      key -> key
    end
  end

  defp normalize_api_key(nil), do: nil

  defp normalize_api_key(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp has_field?(map, key) when is_map(map) and is_atom(key) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end

  defp duration_ms(class, opts) do
    case Keyword.get(opts, :duration_ms) do
      value when is_integer(value) and value > 0 ->
        value

      _ ->
        durations = configured_durations()

        case Map.get(durations, class, 0) do
          value when is_integer(value) and value > 0 -> value
          _ -> 0
        end
    end
  end

  defp configured_durations do
    config = Application.get_env(:pincer, :auth_profile_cooldown, [])
    durations = read_field(config, :durations_ms)

    runtime_map =
      cond do
        is_map(durations) -> durations
        is_list(durations) -> Map.new(durations)
        true -> %{}
      end

    Map.merge(@default_durations, runtime_map)
  end

  defp classify(reason_or_class) when is_atom(reason_or_class), do: reason_or_class
  defp classify(reason_or_class), do: ErrorClass.classify(reason_or_class)

  defp cooldown_key(provider_id, profile_name), do: {provider_id, profile_name}

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp read_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp read_field(list, key) when is_list(list) and is_atom(key) do
    Keyword.get(list, key, Keyword.get(list, to_string(key)))
  end

  defp read_field(_other, _key), do: nil
end
