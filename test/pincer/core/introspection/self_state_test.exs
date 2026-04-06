defmodule Pincer.Core.Introspection.SelfStateTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Introspection.SelfState

  setup do
    Pincer.Infra.Repo.delete_all(Pincer.Core.Introspection.Schema)
    :ok
  end

  describe "load_or_create/1" do
    test "creates a new self-state on first call" do
      {:ok, state} = SelfState.load_or_create("agent_test_1")
      assert state.agent_id == "agent_test_1"
      assert state.wakefulness == "idle"
      assert state.focus == ""
      assert state.concerns == []
      assert state.id != nil
    end

    test "returns existing self-state on subsequent calls" do
      {:ok, first} = SelfState.load_or_create("agent_test_2")
      {:ok, second} = SelfState.load_or_create("agent_test_2")
      assert first.id == second.id
    end
  end

  describe "update/2" do
    test "updates an existing self-state" do
      {:ok, _} = SelfState.load_or_create("agent_test_3")

      {:ok, updated} =
        SelfState.update("agent_test_3", %{
          focus: "testing introspection",
          concerns: ["coverage", "performance"],
          wakefulness: "reflecting"
        })

      assert updated.focus == "testing introspection"
      assert updated.concerns == ["coverage", "performance"]
      assert updated.wakefulness == "reflecting"
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = SelfState.update("nonexistent", %{focus: "x"})
    end
  end

  describe "to_prompt_context/1" do
    test "formats self-state as a compact string" do
      {:ok, _} = SelfState.load_or_create("agent_test_4")

      {:ok, state} =
        SelfState.update("agent_test_4", %{
          focus: "planning next feature",
          concerns: ["deadline", "complexity"],
          open_questions: ["which LLM to use?"],
          last_reflection_summary: "Last session went well."
        })

      context = SelfState.to_prompt_context(state)
      assert context =~ "planning next feature"
      assert context =~ "deadline"
      assert context =~ "which LLM to use?"
      assert context =~ "Last session went well."
    end

    test "handles empty state gracefully" do
      {:ok, state} = SelfState.load_or_create("agent_test_5")
      context = SelfState.to_prompt_context(state)
      assert is_binary(context)
    end
  end
end
