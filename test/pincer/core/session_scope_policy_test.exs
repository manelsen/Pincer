defmodule Pincer.Core.SessionScopePolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.SessionScopePolicy

  describe "resolve/3" do
    test "telegram private chat uses main scope when configured" do
      config = %{"dm_session_scope" => "main"}
      context = %{chat_id: 123, chat_type: "private"}

      assert SessionScopePolicy.resolve(:telegram, context, config) == "telegram_main"
    end

    test "telegram private chat uses per-peer by default" do
      context = %{chat_id: 123, chat_type: "private"}

      assert SessionScopePolicy.resolve(:telegram, context, %{}) == "telegram_123"
    end

    test "telegram non-DM scope is unchanged even when dm_session_scope is main" do
      config = %{"dm_session_scope" => "main"}
      context = %{chat_id: -1001, chat_type: "supergroup"}

      assert SessionScopePolicy.resolve(:telegram, context, config) == "telegram_-1001"
    end

    test "invalid scope falls back to per-peer" do
      config = %{"dm_session_scope" => "invalid-value"}
      context = %{chat_id: 777, chat_type: "private"}

      assert SessionScopePolicy.resolve(:telegram, context, config) == "telegram_777"
    end

    test "discord DM uses main scope when configured" do
      config = %{"dm_session_scope" => "main"}
      context = %{channel_id: 456, guild_id: nil}

      assert SessionScopePolicy.resolve(:discord, context, config) == "discord_main"
    end

    test "discord DM uses per-peer when configured" do
      config = %{"dm_session_scope" => "per-peer"}
      context = %{channel_id: 456, guild_id: nil}

      assert SessionScopePolicy.resolve(:discord, context, config) == "discord_456"
    end

    test "discord DM accepts per_peer alias" do
      config = %{"dm_session_scope" => "per_peer"}
      context = %{channel_id: 999, guild_id: nil}

      assert SessionScopePolicy.resolve(:discord, context, config) == "discord_999"
    end

    test "discord guild scope is unchanged even when dm_session_scope is main" do
      config = %{"dm_session_scope" => "main"}
      context = %{channel_id: 321, guild_id: 42}

      assert SessionScopePolicy.resolve(:discord, context, config) == "discord_321"
    end

    test "whatsapp private chat uses main scope when configured" do
      config = %{"dm_session_scope" => "main"}
      context = %{chat_id: "551199000111", is_group: false}

      assert SessionScopePolicy.resolve(:whatsapp, context, config) == "whatsapp_main"
    end

    test "whatsapp private chat uses per-peer by default" do
      context = %{chat_id: "551199000111", is_group: false}

      assert SessionScopePolicy.resolve(:whatsapp, context, %{}) == "whatsapp_551199000111"
    end

    test "whatsapp group scope stays chat-scoped even when dm_session_scope is main" do
      config = %{"dm_session_scope" => "main"}
      context = %{chat_id: "120363025073717274@g.us", is_group: true}

      assert SessionScopePolicy.resolve(:whatsapp, context, config) ==
               "whatsapp_120363025073717274@g.us"
    end
  end
end
