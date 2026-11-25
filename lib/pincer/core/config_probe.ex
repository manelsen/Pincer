defmodule Pincer.Core.ConfigProbe do
  @moduledoc """
  Shared read-only probes over a parsed `config.yaml` map.

  `Pincer.Core.Doctor`, `Pincer.Core.SecurityAudit` and `Pincer.Core.Onboard`
  all inspect the same config sections with the same normalisation rules but
  report the results differently (severities, ids, messages). This module owns
  the normalisation and the *selection* of what to inspect, so the three
  callers cannot drift on which channels are enabled, how a DM mode is parsed,
  or which channels require a token. Each caller keeps its own report shape.
  """

  alias Pincer.Core.AuthProfiles
  alias Pincer.Utils.MapHelpers

  @channels_requiring_token MapSet.new(["telegram", "discord", "slack", "webhook"])
  @dm_capable_channels MapSet.new(["telegram", "discord", "whatsapp"])

  @type channel_name :: String.t()
  @type channel_config :: map()
  @type dm_mode :: :open | :allowlist | :disabled | :pairing | :missing | :invalid | :malformed
  @type token_state :: :present | :missing_value | :missing_env_key

  @doc "True when a channel requires `token_env` to be configured."
  @spec token_required_channel?(channel_name()) :: boolean()
  def token_required_channel?(name), do: MapSet.member?(@channels_requiring_token, name)

  @doc "Channels that accept a direct-message policy block."
  @spec dm_capable_channel?(channel_name()) :: boolean()
  def dm_capable_channel?(name), do: MapSet.member?(@dm_capable_channels, name)

  @doc "Lists `{normalized_name, config}` pairs for the `channels` section."
  @spec channels(map()) :: [{channel_name(), channel_config()}]
  def channels(config) when is_map(config) do
    case MapHelpers.read_field(config, :channels) do
      channels when is_map(channels) ->
        Enum.map(channels, fn {name, cfg} ->
          {normalize_channel_name(name), normalize_map(cfg)}
        end)

      _ ->
        []
    end
  end

  def channels(_), do: []

  @doc "Lists enabled channels as `{normalized_name, config}` pairs."
  @spec enabled_channels(map()) :: [{channel_name(), channel_config()}]
  def enabled_channels(config) do
    config
    |> channels()
    |> Enum.filter(fn {_name, cfg} -> enabled?(cfg) end)
  end

  @doc "Lists enabled channels that accept a DM policy block."
  @spec enabled_dm_channels(map()) :: [{channel_name(), channel_config()}]
  def enabled_dm_channels(config) do
    config
    |> enabled_channels()
    |> Enum.filter(fn {name, _cfg} -> dm_capable_channel?(name) end)
  end

  @doc "True when the channel config has `enabled` set to `true` or `\"true\"`."
  @spec enabled?(term()) :: boolean()
  def enabled?(cfg) when is_map(cfg) do
    case MapHelpers.read_field(cfg, :enabled) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  def enabled?(_), do: false

  @doc """
  Classifies a channel's token configuration against the environment.

  Returns `:present` when a `token_env` is declared and set, `:missing_value`
  when declared but unset, and `:missing_env_key` when the channel declares no
  `token_env` at all.
  """
  @spec token_state(channel_config(), (String.t() -> String.t() | nil)) :: token_state()
  def token_state(cfg, env_fetcher) when is_map(cfg) do
    case token_env(cfg) do
      nil -> :missing_env_key
      token_env -> env_state(token_env, env_fetcher)
    end
  end

  @doc "Returns the declared `token_env` for a channel config, if any."
  @spec token_env(channel_config()) :: String.t() | nil
  def token_env(cfg) when is_map(cfg) do
    case MapHelpers.read_field(cfg, :token_env) do
      value when is_binary(value) -> if MapHelpers.present?(value), do: value
      _ -> nil
    end
  end

  @doc "Returns the token state and environment key for each applicable enabled channel."
  @spec channel_tokens(map(), (String.t() -> String.t() | nil)) ::
          [{channel_name(), String.t() | nil, token_state()}]
  def channel_tokens(config, env_fetcher) do
    for {channel, cfg} <- enabled_channels(config),
        state = token_state(cfg, env_fetcher),
        state != :missing_env_key or token_required_channel?(channel) do
      {channel, token_env(cfg), state}
    end
  end

  @doc "Returns the selected provider's credential state, or `nil` when no provider is selected."
  @spec provider_env(map(), map(), (String.t() -> String.t() | nil)) ::
          {String.t(), String.t() | nil,
           :unregistered | :not_required | :present | :missing_value | :invalid_auth_config}
          | nil
  def provider_env(config, registry, env_fetcher) do
    provider = config |> MapHelpers.read_field(:llm) |> MapHelpers.read_field(:provider)

    if is_binary(provider) and String.trim(provider) != "" do
      provider = String.trim(provider)

      case MapHelpers.read_field(registry, provider) do
        entry when is_map(entry) ->
          case AuthProfiles.configured_env_keys(entry) do
            {:ok, []} ->
              {provider, nil, :not_required}

            {:ok, [first | _] = keys} ->
              case Enum.find(keys, &(env_state(&1, env_fetcher) == :present)) do
                nil -> {provider, first, :missing_value}
                key -> {provider, key, :present}
              end

            {:error, :invalid_auth_config} ->
              {provider, nil, :invalid_auth_config}
          end

        _ ->
          {provider, nil, :unregistered}
      end
    end
  end

  defp env_state(key, env_fetcher) do
    if MapHelpers.present?(env_fetcher.(key)), do: :present, else: :missing_value
  end

  @doc "Normalises a DM mode from a `dm_policy` map."
  @spec dm_mode(term()) :: dm_mode()
  def dm_mode(nil), do: :missing

  def dm_mode(dm_policy) when is_map(dm_policy) do
    dm_policy
    |> MapHelpers.read_field(:mode)
    |> dm_mode_value()
  end

  def dm_mode(_), do: :malformed

  @doc "Normalises a raw DM mode value."
  @spec dm_mode_value(term()) :: dm_mode()
  def dm_mode_value(nil), do: :missing
  def dm_mode_value(""), do: :missing

  def dm_mode_value(value) when is_binary(value) or is_atom(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "open" -> :open
      "allowlist" -> :allowlist
      "disabled" -> :disabled
      "pairing" -> :pairing
      _ -> :invalid
    end
  end

  def dm_mode_value(value) when is_list(value) do
    with text when is_binary(text) <- :unicode.characters_to_binary(value),
         mode when mode in [:open, :allowlist, :disabled, :pairing] <- dm_mode_value(text) do
      mode
    else
      _ -> :malformed
    end
  rescue
    ArgumentError -> :malformed
  end

  def dm_mode_value(_), do: :malformed

  @doc "Uses open for absent or unrecognized string modes and disables malformed policies."
  @spec effective_dm_mode(term()) :: :open | :allowlist | :disabled | :pairing
  def effective_dm_mode(policy) do
    case dm_mode(policy) do
      mode when mode in [:missing, :invalid] -> :open
      :malformed -> :disabled
      mode -> mode
    end
  end

  @doc "Lowercases and trims a channel name."
  @spec normalize_channel_name(term()) :: channel_name()
  def normalize_channel_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  @doc "Returns the map unchanged, or `%{}` for non-maps."
  @spec normalize_map(term()) :: map()
  def normalize_map(map) when is_map(map), do: map
  def normalize_map(_), do: %{}
end
