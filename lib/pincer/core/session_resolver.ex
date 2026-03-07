defmodule Pincer.Core.SessionResolver do
  @moduledoc """
  Resolves channel metadata into a session context.

  `session_id` remains a conversation/runtime concern.
  `root_agent_id` is the canonical owner of persona, workspace and blackboard.
  """

  alias Pincer.Core.Bindings
  alias Pincer.Core.Session.Context
  alias Pincer.Core.SessionScopePolicy

  @type channel :: :telegram | :discord | :whatsapp

  @doc """
  Resolves channel context and config into a `%Session.Context{}`.
  """
  @spec resolve(channel(), map(), map()) :: Context.t()
  def resolve(channel, context, channel_config \\ %{})

  def resolve(:telegram, context, channel_config) do
    chat_id = read_field(context, :chat_id)
    chat_type = normalize_chat_type(read_field(context, :chat_type))
    session_id = SessionScopePolicy.resolve(:telegram, context, channel_config)
    conversation_ref = conversation_ref(:telegram, chat_type, chat_id)

    {principal_ref, root_agent_id, root_agent_source} =
      if chat_type == "private" do
        principal_ref = Bindings.principal_ref(:telegram, :user, chat_id)
        resolve_root_agent(principal_ref, chat_id, session_id, channel_config)
      else
        {nil, session_id, :session_scope}
      end

    Context.new(
      channel: :telegram,
      session_id: session_id,
      principal_ref: principal_ref,
      conversation_ref: conversation_ref,
      root_agent_id: root_agent_id,
      root_agent_source: root_agent_source
    )
  end

  def resolve(:discord, context, channel_config) do
    channel_id = read_field(context, :channel_id)
    guild_id = read_field(context, :guild_id)
    sender_id = read_field(context, :sender_id)
    session_id = SessionScopePolicy.resolve(:discord, context, channel_config)
    conversation_ref = conversation_ref(:discord, guild_id, channel_id)

    {principal_ref, root_agent_id, root_agent_source} =
      if dm_event?(guild_id) do
        principal_ref = Bindings.principal_ref(:discord, :user, sender_id || channel_id)
        resolve_root_agent(principal_ref, sender_id || channel_id, session_id, channel_config)
      else
        {nil, session_id, :session_scope}
      end

    Context.new(
      channel: :discord,
      session_id: session_id,
      principal_ref: principal_ref,
      conversation_ref: conversation_ref,
      root_agent_id: root_agent_id,
      root_agent_source: root_agent_source
    )
  end

  def resolve(:whatsapp, context, channel_config) do
    chat_id = read_field(context, :chat_id)
    is_group = truthy?(read_field(context, :is_group))
    sender_id = read_field(context, :sender_id) || chat_id
    session_id = SessionScopePolicy.resolve(:whatsapp, context, channel_config)
    conversation_ref = conversation_ref(:whatsapp, if(is_group, do: :group, else: :dm), chat_id)

    {principal_ref, root_agent_id, root_agent_source} =
      if is_group do
        {nil, session_id, :session_scope}
      else
        principal_ref = Bindings.principal_ref(:whatsapp, :user, sender_id)
        resolve_root_agent(principal_ref, sender_id, session_id, channel_config)
      end

    Context.new(
      channel: :whatsapp,
      session_id: session_id,
      principal_ref: principal_ref,
      conversation_ref: conversation_ref,
      root_agent_id: root_agent_id,
      root_agent_source: root_agent_source
    )
  end

  def resolve(_channel, context, _config) do
    session_id = SessionScopePolicy.resolve(:unknown, context, %{})

    Context.new(
      session_id: session_id,
      conversation_ref: Bindings.conversation_ref(:unknown, :conversation, session_id),
      root_agent_id: session_id,
      root_agent_source: :session_scope
    )
  end

  defp resolve_root_agent(principal_ref, external_id, session_id, channel_config) do
    case mapped_agent_id(channel_config, external_id) do
      agent_id when is_binary(agent_id) ->
        {principal_ref, agent_id, :static_mapping}

      nil ->
        case Bindings.resolve(principal_ref) do
          agent_id when is_binary(agent_id) ->
            {principal_ref, agent_id, :binding}

          nil ->
            {principal_ref, session_id, :session_scope}
        end
    end
  end

  defp conversation_ref(:telegram, "private", chat_id),
    do: Bindings.conversation_ref(:telegram, :dm, chat_id)

  defp conversation_ref(:telegram, _chat_type, chat_id),
    do: Bindings.conversation_ref(:telegram, :chat, chat_id)

  defp conversation_ref(:discord, guild_id, channel_id) when guild_id in [nil, ""],
    do: Bindings.conversation_ref(:discord, :dm, channel_id)

  defp conversation_ref(:discord, _guild_id, channel_id),
    do: Bindings.conversation_ref(:discord, :channel, channel_id)

  defp conversation_ref(channel, kind, external_id),
    do: Bindings.conversation_ref(channel, kind, external_id)

  defp mapped_agent_id(config, external_id) do
    normalized_external_id = stringify(external_id)

    case read_field(config, :agent_map) do
      agent_map when is_map(agent_map) ->
        agent_map
        |> Enum.find_value(fn {key, value} ->
          if stringify(key) == normalized_external_id do
            normalize_agent_id(value)
          else
            nil
          end
        end)

      _ ->
        nil
    end
  end

  defp normalize_agent_id(nil), do: nil

  defp normalize_agent_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      agent_id -> agent_id
    end
  end

  defp normalize_chat_type(nil), do: ""

  defp normalize_chat_type(chat_type) do
    chat_type
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp dm_event?(nil), do: true
  defp dm_event?(""), do: true
  defp dm_event?(guild_id) when is_binary(guild_id), do: String.trim(guild_id) == ""
  defp dm_event?(_), do: false

  defp truthy?(value) when value in [true, "true", 1, "1", true], do: true
  defp truthy?(_), do: false

  defp stringify(nil), do: ""
  defp stringify(value), do: value |> to_string() |> String.trim()

  defp read_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp read_field(_, _), do: nil
end
