defmodule Pincer.Core.Heartbeat.ContractEngineTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Heartbeat.ContractEngine

  describe "make_promise/3" do
    test "stores a promise for an agent" do
      :ok = ContractEngine.make_promise("agent_1", "Monitor repo X for new commits")

      pending = ContractEngine.pending("agent_1")
      assert length(pending) == 1

      [p] = pending
      assert p.description == "Monitor repo X for new commits"
      assert p.status == :pending
      assert p.id =~ ~r/^promise_/
    end

    test "isolates promises per agent" do
      :ok = ContractEngine.make_promise("agent_a", "Task A")
      :ok = ContractEngine.make_promise("agent_b", "Task B")

      assert length(ContractEngine.pending("agent_a")) == 1
      assert length(ContractEngine.pending("agent_b")) == 1
    end
  end

  describe "evaluate/1" do
    test "marks promises as expired past deadline" do
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      :ok = ContractEngine.make_promise("agent_2", "Expired task", deadline: past)

      results = ContractEngine.evaluate("agent_2")

      assert [{:expired, p}] = results
      assert p.status == :expired
    end

    test "keeps pending promises within deadline" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      :ok = ContractEngine.make_promise("agent_3", "Active task", deadline: future)

      results = ContractEngine.evaluate("agent_3")

      assert [{:pending, p}] = results
      assert p.status == :pending
    end

    test "returns empty list for agent with no promises" do
      assert ContractEngine.evaluate("nonexistent") == []
    end

    test "returns all promises with their statuses" do
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      :ok = ContractEngine.make_promise("agent_4", "Expired", deadline: past)
      :ok = ContractEngine.make_promise("agent_4", "Active", deadline: future)

      results = ContractEngine.evaluate("agent_4")
      assert length(results) == 2

      statuses = Enum.map(results, fn {status, _} -> status end) |> Enum.sort()
      assert :expired in statuses
      assert :pending in statuses
    end
  end

  describe "pending/1" do
    test "returns only pending promises after evaluate" do
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      :ok = ContractEngine.make_promise("agent_5", "Expired", deadline: past)
      :ok = ContractEngine.make_promise("agent_5", "Active", deadline: future)

      ContractEngine.evaluate("agent_5")

      pending = ContractEngine.pending("agent_5")
      assert length(pending) == 1
      assert hd(pending).description == "Active"
    end

    test "returns empty list for unknown agent" do
      assert ContractEngine.pending("unknown") == []
    end
  end

  describe "fulfill/2" do
    test "marks a specific promise as fulfilled" do
      :ok = ContractEngine.make_promise("agent_6", "Complete task")

      [p] = ContractEngine.pending("agent_6")
      :ok = ContractEngine.fulfill("agent_6", p.id)

      pending = ContractEngine.pending("agent_6")
      assert pending == []
    end
  end
end
