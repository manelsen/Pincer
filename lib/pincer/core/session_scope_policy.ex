defmodule Pincer.Core.SessionScopePolicy do
  @moduledoc """
  Core DM session scope policy shared by channel adapters.

  This policy controls how DM session IDs are resolved:
  - `main`: all DMs of a channel share one session
  - `per-peer`: each DM peer keeps an isolated session

  Non-DM routes always remain channel-scoped.
  """

  @type channel :: :telegram | :discord
  @type dm_scope :: :main | :per_peer

  @doc """
  Resolves a session ID for a channel context and config.

  Config key:
  - `dm_session_scope` (`"main"` or `"per-peer"`; alias `"per_peer"`)

  Missing/invalid values default to `per-peer` for backward compatibility.
  """
  @spec resolve(channel(), map(), map()) :: String.t()
  def resolve(channel, context, channel_config \\ %{})

  def resolve(:telegram, context, channel_config)
      when is_map(context) and is_map(channel_config) do
    chat_id = stringify(read_field(context, :chat_id))
    chat_type = normalize_chat_type(read_field(context, :chat_type))

    if chat_type == "private" do
      case dm_scope(channel_config) do
        :main -> "telegram_main"
        :per_peer -> scoped_id("telegram", chat_id)
      end
    else
      scoped_id("telegram", chat_id)
    end
  end

  def resolve(:discord, context, channel_config)
      when is_map(context) and is_map(channel_config) do
    channel_id = stringify(read_field(context, :channel_id))
    guild_id = read_field(context, :guild_id)

    if dm_event?(guild_id) do
      case dm_scope(channel_config) do
        :main -> "discord_main"
        :per_peer -> scoped_id("discord", channel_id)
      end
    else
      scoped_id("discord", channel_id)
    end
  end

  def resolve(_channel, context, _channel_config) when is_map(context) do
    id =
      read_field(context, :chat_id) ||
        read_field(context, :channel_id) ||
        "unknown"

    scoped_id("unknown", stringify(id))
  end

  defp dm_scope(config) do
    raw =
      read_field(config, :dm_session_scope) ||
        read_field(config, :dm_scope) ||
        read_nested_dm_scope(config)

    normalize_dm_scope(raw)
  end

  defp read_nested_dm_scope(config) do
    case read_field(config, :session_scope) do
      scope_map when is_map(scope_map) -> read_field(scope_map, :dm)
      _ -> nil
    end
  end

  defp normalize_dm_scope(nil), do: :per_peer
  defp normalize_dm_scope(""), do: :per_peer

  defp normalize_dm_scope(scope) do
    normalized =
      scope
      |> to_string()
      |> String.trim()
      |> String.downcase()

    case normalized do
      "main" -> :main
      "per-peer" -> :per_peer
      "per_peer" -> :per_peer
      "perpeer" -> :per_peer
      "peer" -> :per_peer
      _ -> :per_peer
    end
  end

  defp dm_event?(nil), do: true
  defp dm_event?(""), do: true
  defp dm_event?(guild_id) when is_binary(guild_id), do: String.trim(guild_id) == ""
  defp dm_event?(_), do: false

  defp scoped_id(prefix, ""), do: "#{prefix}_unknown"
  defp scoped_id(prefix, id), do: "#{prefix}_#{id}"

  defp normalize_chat_type(nil), do: ""

  defp normalize_chat_type(chat_type),
    do: chat_type |> to_string() |> String.trim() |> String.downcase()

  defp stringify(nil), do: ""
  defp stringify(value), do: value |> to_string() |> String.trim()

  defp read_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp read_field(_, _), do: nil
end
