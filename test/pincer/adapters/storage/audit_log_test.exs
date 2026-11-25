defmodule Pincer.Adapters.Storage.AuditLogTest do
  use ExUnit.Case, async: false

  alias Pincer.Infra.SQLite
  alias Pincer.Ports.AuditLog

  test "reads a previously stored security event through the audit port" do
    actor = "audit-#{System.unique_integer([:positive])}"

    assert :ok =
             SQLite.execute(
               SQLite.default_server(),
               """
               INSERT INTO audit_log (id, actor, event_type, outcome, metadata, inserted_at)
               VALUES (?, ?, 'approval', 'allowed', '{"source":"saved"}', '2026-01-01T00:00:00Z')
               """,
               [actor, actor]
             )

    assert [%{actor: ^actor, metadata: %{"source" => "saved"}, inserted_at: %DateTime{}}] =
             AuditLog.list({:actor, actor}, 1)

    assert [] = AuditLog.list({:actor, actor}, 0)
  end
end
