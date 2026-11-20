defmodule Pincer.Core.Session.ApprovalTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Session.Approval

  describe "parse_decision/1" do
    test "recognizes PT and EN approval tokens" do
      for token <- ["aprovo", "Aprovo", " sim ", "YES", "approve", "ok", "s", "y"] do
        assert Approval.parse_decision(token) == :approved
      end
    end

    test "recognizes PT and EN rejection tokens" do
      for token <- ["rejeito", "NÃO", " nao ", "no", "REJECT", "n"] do
        assert Approval.parse_decision(token) == :rejected
      end
    end

    test "returns :unknown for unrecognized inputs" do
      assert Approval.parse_decision("talvez depois") == :unknown
      assert Approval.parse_decision("") == :unknown
    end
  end

  describe "cancel_command?/1" do
    test "recognizes interruption commands case-insensitively" do
      for cmd <- ["para", "STOP", " cancel ", "cancela", "/stop", "/cancel"] do
        assert Approval.cancel_command?(cmd)
      end

      refute Approval.cancel_command?("continue please")
    end
  end

  describe "auto_approve_active?/2" do
    test "returns false when nil or in the past/present, true when in the future" do
      now = ~U[2026-11-19 12:00:00Z]
      refute Approval.auto_approve_active?(nil, now)
      refute Approval.auto_approve_active?(~U[2026-11-19 11:59:59Z], now)
      refute Approval.auto_approve_active?(now, now)
      assert Approval.auto_approve_active?(~U[2026-11-19 12:05:00Z], now)
    end
  end

  describe "handle_request/4" do
    test "returns {:auto_approved, call_id} when auto-approve is active" do
      now = ~U[2026-11-19 12:00:00Z]
      until = ~U[2026-11-19 12:10:00Z]

      assert {:auto_approved, "call_1"} == Approval.handle_request("call_1", "ls", until, now)
    end

    test "returns {:pending, {call_id, command}} when auto-approve is inactive" do
      now = ~U[2026-11-19 12:00:00Z]

      assert {:pending, {"call_2", "rm -rf /tmp/x"}} ==
               Approval.handle_request("call_2", "rm -rf /tmp/x", nil, now)
    end
  end

  describe "enable_auto_approve/3" do
    test "computes expiration, clears pending approval, and returns {:auto_approve, call_id}" do
      now = ~U[2026-11-19 12:00:00Z]

      assert {~U[2026-11-19 12:10:00Z], nil, {:auto_approve, "call_9"}} ==
               Approval.enable_auto_approve({"call_9", "ls"}, 600, now)
    end

    test "returns :noop when there is no pending approval or duration is non-positive" do
      now = ~U[2026-11-19 12:00:00Z]

      assert {~U[2026-11-19 12:10:00Z], nil, :noop} ==
               Approval.enable_auto_approve(nil, 600, now)

      assert {now, {"call_9", "ls"}, :noop} ==
               Approval.enable_auto_approve({"call_9", "ls"}, 0, now)
    end
  end

  describe "resolve_pending/2" do
    test "resolves pending decision or asks again" do
      assert {:decided, "call_1", :approved} ==
               Approval.resolve_pending({"call_1", "ls"}, "aprovo")

      assert {:decided, "call_1", :rejected} ==
               Approval.resolve_pending({"call_1", "ls"}, "rejeito")

      assert {:prompt_again, {"call_1", "ls"}} ==
               Approval.resolve_pending({"call_1", "ls"}, "what?")
    end
  end
end
