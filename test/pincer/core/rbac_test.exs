defmodule Pincer.Core.RBACTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.RBAC

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
end
