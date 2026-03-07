defmodule Pincer.Core.PairingTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Pincer.Core.Pairing

  setup do
    Pairing.reset()

    on_exit(fn ->
      Pairing.reset()
    end)

    :ok
  end

  describe "issue_code/3 and approve_code/4" do
    test "logs pairing metadata with readable expiration and ready-to-use command" do
      log =
        capture_log(fn ->
          assert {:ok, %{code: "123456", expires_at_ms: 61_000}} =
                   Pairing.issue_code(:telegram, "user-log",
                     now_ms: 1_000,
                     ttl_ms: 60_000,
                     code_generator: fn -> "123456" end
                   )
        end)

      assert log =~ "[PAIRING] issued channel=telegram sender=user-log code=123456"
      assert log =~ "expires_at="
      assert log =~ "ttl_s=60"
      assert log =~ "command=/pair 123456"
    end

    test "issues code, approves once, and blocks replay approval" do
      assert {:ok, %{code: code, expires_at_ms: expires_at_ms}} =
               Pairing.issue_code(:telegram, "user-1",
                 now_ms: 1_000,
                 ttl_ms: 60_000,
                 code_generator: fn -> "123456" end
               )

      assert code == "123456"
      assert expires_at_ms == 61_000

      assert :ok == Pairing.approve_code(:telegram, "user-1", code, now_ms: 1_001)
      assert Pairing.paired?(:telegram, "user-1")

      assert {:error, :not_pending} =
               Pairing.approve_code(:telegram, "user-1", code, now_ms: 1_002)
    end

    test "returns expired when approval happens after replay window" do
      assert {:ok, %{code: code}} =
               Pairing.issue_code(:discord, "user-2",
                 now_ms: 10,
                 ttl_ms: 100,
                 code_generator: fn -> "222222" end
               )

      assert {:error, :expired} = Pairing.approve_code(:discord, "user-2", code, now_ms: 111)
      refute Pairing.paired?(:discord, "user-2")
    end

    test "locks pending code after max invalid attempts" do
      assert {:ok, %{}} =
               Pairing.issue_code(:telegram, "user-3",
                 now_ms: 0,
                 ttl_ms: 1_000,
                 max_attempts: 2,
                 code_generator: fn -> "333333" end
               )

      assert {:error, :invalid_code} =
               Pairing.approve_code(:telegram, "user-3", "000000", now_ms: 1, max_attempts: 2)

      assert {:error, :attempts_exceeded} =
               Pairing.approve_code(:telegram, "user-3", "111111", now_ms: 2, max_attempts: 2)

      assert {:error, :not_pending} =
               Pairing.approve_code(:telegram, "user-3", "333333", now_ms: 3, max_attempts: 2)
    end

    test "paired state survives runtime table recreation (persistent store)" do
      assert {:ok, %{code: code}} =
               Pairing.issue_code(:telegram, "user-persist",
                 now_ms: 1_000,
                 ttl_ms: 60_000,
                 code_generator: fn -> "555555" end
               )

      assert :ok = Pairing.approve_code(:telegram, "user-persist", code, now_ms: 1_001)
      assert Pairing.paired?(:telegram, "user-persist")

      delete_runtime_table(:pincer_pairing_pending)
      delete_runtime_table(:pincer_pairing_pairs)

      assert Pairing.paired?(:telegram, "user-persist")
    end

    test "approve_code accepts targeted invite codes and binds sender to explicit agent" do
      assert {:ok, %{code: "ANNIE42", expires_at_ms: 61_000, agent_id: "annie"}} =
               Pairing.issue_invite(:telegram,
                 agent_id: "annie",
                 now_ms: 1_000,
                 ttl_ms: 60_000,
                 code_generator: fn -> "ANNIE42" end
               )

      assert :ok =
               Pairing.approve_code(:telegram, "123", "ANNIE42",
                 now_ms: 1_001,
                 default_agent_id: "telegram_123"
               )

      assert Pairing.paired?(:telegram, "123")
      assert Pairing.bound_agent_id(:telegram, "123") == "annie"
      assert Pairing.bound_agent_session?(:telegram, "annie")
    end

    test "approve_code binds generic invite codes to a dedicated telegram agent" do
      assert {:ok, %{code: "GENERIC42", expires_at_ms: 61_000, agent_id: nil}} =
               Pairing.issue_invite(:telegram,
                 now_ms: 1_000,
                 ttl_ms: 60_000,
                 code_generator: fn -> "GENERIC42" end
               )

      assert :ok =
               Pairing.approve_code(:telegram, "456", "GENERIC42",
                 now_ms: 1_001,
                 agent_factory: fn -> "a1b2c3" end
               )

      assert Pairing.bound_agent_id(:telegram, "456") == "a1b2c3"
    end

    test "valid invite code overrides legacy sender-bound pending state" do
      assert {:ok, %{code: "111111"}} =
               Pairing.issue_code(:telegram, "123",
                 now_ms: 1_000,
                 ttl_ms: 60_000,
                 code_generator: fn -> "111111" end
               )

      assert {:ok, %{code: "ANNIE42"}} =
               Pairing.issue_invite(:telegram,
                 agent_id: "annie",
                 now_ms: 1_000,
                 ttl_ms: 60_000,
                 code_generator: fn -> "ANNIE42" end
               )

      assert :ok =
               Pairing.approve_code(:telegram, "123", "ANNIE42",
                 now_ms: 1_001,
                 default_agent_id: "telegram_123"
               )

      assert Pairing.bound_agent_id(:telegram, "123") == "annie"

      assert {:error, :not_pending} =
               Pairing.approve_code(:telegram, "123", "111111", now_ms: 1_002)
    end
  end

  describe "reject_code/4" do
    test "rejects pending request and removes code from workflow" do
      assert {:ok, %{code: code}} =
               Pairing.issue_code(:telegram, "user-4",
                 now_ms: 0,
                 ttl_ms: 1_000,
                 code_generator: fn -> "444444" end
               )

      assert :ok == Pairing.reject_code(:telegram, "user-4", code, now_ms: 1)

      assert {:error, :not_pending} =
               Pairing.approve_code(:telegram, "user-4", code, now_ms: 2)
    end
  end

  defp delete_runtime_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ok
      _ -> :ets.delete(table)
    end
  end
end
