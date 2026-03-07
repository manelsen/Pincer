defmodule Pincer.Core.SessionScopePolicyTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Pairing
  alias Pincer.Core.SessionScopePolicy

  setup do
    Pairing.reset()

    on_exit(fn ->
      Pairing.reset()
    end)

    :ok
  end

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

    test "telegram private chat keeps session scope stable even when agent_map exists" do
      config = %{
        "dm_session_scope" => "main",
        "agent_map" => %{"123" => "annie", "456" => "lucie"}
      }

      annie_context = %{chat_id: 123, chat_type: "private"}
      lucie_context = %{chat_id: 456, chat_type: "private"}

      assert SessionScopePolicy.resolve(:telegram, annie_context, config) == "telegram_main"
      assert SessionScopePolicy.resolve(:telegram, lucie_context, config) == "telegram_main"
    end

    test "telegram private chat ignores dynamic binding when resolving session scope" do
      assert {:ok, %{code: "ANNIE42"}} =
               Pairing.issue_invite(:telegram,
                 agent_id: "annie",
                 code_generator: fn -> "ANNIE42" end
               )

      assert :ok =
               Pairing.approve_code(:telegram, "123", "ANNIE42", default_agent_id: "telegram_123")

      context = %{chat_id: 123, chat_type: "private"}

      assert SessionScopePolicy.resolve(:telegram, context, %{}) == "telegram_123"
    end

    test "telegram private chat still respects dm_session_scope when both map and binding exist" do
      assert {:ok, %{code: "ANNIE42"}} =
               Pairing.issue_invite(:telegram,
                 agent_id: "annie",
                 code_generator: fn -> "ANNIE42" end
               )

      assert :ok =
               Pairing.approve_code(:telegram, "123", "ANNIE42", default_agent_id: "telegram_123")

      config = %{"agent_map" => %{"123" => "lucie"}}
      context = %{chat_id: 123, chat_type: "private"}

      assert SessionScopePolicy.resolve(:telegram, context, config) == "telegram_123"
    end

    test "telegram generic pairing binding does not override dm main session scope" do
      assert {:ok, %{code: "GENERIC42"}} =
               Pairing.issue_invite(:telegram, code_generator: fn -> "GENERIC42" end)

      assert :ok =
               Pairing.approve_code(:telegram, "123", "GENERIC42",
                 agent_factory: fn -> "a1b2c3" end
               )

      config = %{"dm_session_scope" => "main"}
      context = %{chat_id: 123, chat_type: "private"}

      assert SessionScopePolicy.resolve(:telegram, context, config) == "telegram_main"
    end

    test "telegram non-DM ignores agent_map and remains chat-scoped" do
      config = %{"agent_map" => %{"-1001" => "group_agent"}}
      context = %{chat_id: -1001, chat_type: "supergroup"}

      assert SessionScopePolicy.resolve(:telegram, context, config) == "telegram_-1001"
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
