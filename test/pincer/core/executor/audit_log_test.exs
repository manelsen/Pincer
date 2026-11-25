defmodule Pincer.Core.Executor.AuditLogTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Executor.AuditLog
  alias Pincer.Infra.SQLite

  setup do
    :ok = SQLite.execute("DELETE FROM audit_log")
    :ok
  end

  test "records an audit event" do
    assert :ok =
             AuditLog.record("tool_approval", "approved", actor: "user_123", target: "safe_shell")

    [log] = AuditLog.recent(1)
    assert log.event_type == "tool_approval"
    assert log.outcome == "approved"
    assert log.actor == "user_123"
    assert log.target == "safe_shell"
  end

  test "queries by actor" do
    AuditLog.record("auth_failure", "denied", actor: "attacker")
    AuditLog.record("message_sent", "ok", actor: "friend")

    logs = AuditLog.by_actor("attacker")
    assert length(logs) == 1
    assert hd(logs).actor == "attacker"
  end

  test "queries by type" do
    AuditLog.record("policy_denial", "blocked")
    AuditLog.record("llm_call", "ok")

    logs = AuditLog.by_type("policy_denial")
    assert length(logs) == 1
    assert hd(logs).event_type == "policy_denial"
  end
end
