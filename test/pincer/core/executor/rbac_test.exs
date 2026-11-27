defmodule Pincer.Core.Executor.RBACTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Executor.Ctx
  alias Pincer.Core.Executor.RBAC

  setup do
    keys = [:agents, :channels, :rbac, :security, :rbac_unconfigured_role]
    snapshot = Map.new(keys, fn key -> {key, Application.get_env(:pincer, key, :__unset__)} end)

    on_exit(fn ->
      Enum.each(snapshot, fn
        {key, :__unset__} -> Application.delete_env(:pincer, key)
        {key, value} -> Application.put_env(:pincer, key, value)
      end)
    end)

    :ok
  end

  test "admin has all permissions" do
    assert RBAC.can?(:admin, :approve_tools)
    assert RBAC.can?(:admin, :view_audit_log)
    assert RBAC.can?(:admin, :override_policy)
  end

  test "operator has limited management permissions" do
    assert RBAC.can?(:operator, :approve_tools)
    assert RBAC.can?(:operator, :view_audit_log)
    refute RBAC.can?(:operator, :override_policy)
  end

  test "bot only has basic permissions" do
    assert RBAC.can?(:bot, :send_message)
    refute RBAC.can?(:bot, :approve_tools)
    refute RBAC.can?(:bot, :view_audit_log)
  end

  test "authorize returns :ok or {:error, :forbidden}" do
    assert :ok = RBAC.authorize(:admin, :change_config)
    assert {:error, :forbidden} = RBAC.authorize(:bot, :change_config)
  end

  test "role_for defaults to :bot" do
    assert RBAC.role_for("unknown_agent") == :bot
  end

  describe "configured_role_for/1" do
    test "returns nil for agents without an explicit role" do
      Application.delete_env(:pincer, :agents)
      assert RBAC.configured_role_for("unknown_agent") == nil
    end

    test "returns atom and YAML string-keyed configured roles and fails closed on invalid strings" do
      Application.put_env(:pincer, :agents, %{
        "agent-x" => %{role: "operator"},
        "agent-yaml" => %{"role" => "admin"},
        "agent-bad" => %{"role" => "superuser"}
      })

      assert RBAC.configured_role_for("agent-x") == :operator
      assert RBAC.configured_role_for("agent-yaml") == :admin
      assert RBAC.configured_role_for("agent-bad") == :bot
      assert RBAC.configured_role_for("missing") == nil
    end
  end

  describe "effective_role/1" do
    test "resolves agent_id > session_id > channel default_role > unconfigured_role" do
      Application.put_env(:pincer, :agents, %{
        "annie" => %{"role" => "operator"},
        "telegram_200" => %{"role" => "admin"}
      })

      Application.put_env(:pincer, :channels, %{
        "telegram" => %{"default_role" => "bot"}
      })

      Application.put_env(:pincer, :rbac, %{"unconfigured_role" => "bot"})

      paired_ctx = Ctx.new(self(), "telegram_123", agent_id: "annie", channel: :telegram)
      assert RBAC.effective_role(paired_ctx) == :operator

      session_fallback_ctx = Ctx.new(self(), "telegram_200", channel: :telegram)
      assert RBAC.effective_role(session_fallback_ctx) == :admin

      channel_default_ctx = Ctx.new(self(), "telegram_999", channel: :telegram)
      assert RBAC.effective_role(channel_default_ctx) == :bot

      unmapped_discord_ctx = Ctx.new(self(), "discord_555", channel: :discord)
      assert RBAC.effective_role(unmapped_discord_ctx) == :bot
    end

    test "defaults unconfigured sessions to :operator unless tightened by channel or rbac config" do
      Application.delete_env(:pincer, :agents)
      Application.delete_env(:pincer, :channels)
      Application.delete_env(:pincer, :rbac)

      ctx = Ctx.new(self(), "telegram_unmapped_1")
      assert RBAC.effective_role(ctx) == :operator

      Application.put_env(:pincer, :rbac, %{"unconfigured_role" => "invalid_value"})
      assert RBAC.effective_role(ctx) == :bot
    end
  end
end
