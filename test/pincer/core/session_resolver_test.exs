defmodule Pincer.Core.SessionResolverTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Bindings
  alias Pincer.Core.Pairing
  alias Pincer.Core.SessionResolver

  setup do
    Pairing.reset()

    on_exit(fn ->
      Pairing.reset()
    end)

    :ok
  end

  test "telegram DM keeps chat-scoped session_id while resolving explicit root agent from binding" do
    principal_ref = Bindings.principal_ref(:telegram, :user, 123)
    assert :ok = Bindings.bind(principal_ref, "a1b2c3")

    context =
      SessionResolver.resolve(
        :telegram,
        %{chat_id: 123, chat_type: "private"},
        %{}
      )

    assert context.session_id == "telegram_123"
    assert context.principal_ref == "telegram:user:123"
    assert context.conversation_ref == "telegram:dm:123"
    assert context.root_agent_id == "a1b2c3"
    assert context.root_agent_source == :binding
  end

  test "telegram static agent_map overrides dynamic binding for root agent only" do
    principal_ref = Bindings.principal_ref(:telegram, :user, 123)
    assert :ok = Bindings.bind(principal_ref, "a1b2c3")

    context =
      SessionResolver.resolve(
        :telegram,
        %{chat_id: 123, chat_type: "private"},
        %{"agent_map" => %{"123" => "lucie"}}
      )

    assert context.session_id == "telegram_123"
    assert context.root_agent_id == "lucie"
    assert context.root_agent_source == :static_mapping
  end

  test "discord separates principal identity from dm conversation identity" do
    principal_ref = Bindings.principal_ref(:discord, :user, "user-9")
    assert :ok = Bindings.bind(principal_ref, "beef42")

    context =
      SessionResolver.resolve(
        :discord,
        %{channel_id: 456, guild_id: nil, sender_id: "user-9"},
        %{}
      )

    assert context.session_id == "discord_456"
    assert context.principal_ref == "discord:user:user-9"
    assert context.conversation_ref == "discord:dm:456"
    assert context.root_agent_id == "beef42"
  end

  test "whatsapp falls back to conversation-scoped root agent when no binding exists" do
    context =
      SessionResolver.resolve(
        :whatsapp,
        %{chat_id: "551199000111", sender_id: "551199000111", is_group: false},
        %{}
      )

    assert context.session_id == "whatsapp_551199000111"
    assert context.root_agent_id == "whatsapp_551199000111"
    assert context.root_agent_source == :session_scope
  end
end
