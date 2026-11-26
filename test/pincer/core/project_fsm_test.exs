defmodule Pincer.Core.ProjectFSMTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ProjectFSM

  defmodule StorageStub do
    def save_checkpoint(session_id, checkpoint) do
      send(self(), {:checkpoint_saved, session_id, checkpoint})
      {:ok, %{id: "chk-1"}}
    end
  end

  test "supports explicit lifecycle transitions in order" do
    state = ProjectFSM.new("project-1", "session-1")

    assert {:ok, s1} =
             ProjectFSM.transition(state, :scope, %{objective: "Ship project"},
               storage: StorageStub
             )

    assert s1.phase == :scope

    assert {:ok, s2} =
             ProjectFSM.transition(s1, :plan, %{scope: "channels + core"}, storage: StorageStub)

    assert s2.phase == :plan

    assert {:ok, s3} =
             ProjectFSM.transition(s2, :execution, %{plan: %{tasks: 3}}, storage: StorageStub)

    assert s3.phase == :execution

    assert {:ok, s4} =
             ProjectFSM.transition(s3, :review, %{execution: %{done: true}}, storage: StorageStub)

    assert s4.phase == :review

    assert {:ok, s5} =
             ProjectFSM.transition(s4, :delivery, %{review: %{approved: true}},
               storage: StorageStub
             )

    assert s5.phase == :delivery
  end

  test "rejects invalid transitions with explicit reason payload" do
    state = ProjectFSM.new("project-2", "session-2")

    assert {:error, {:invalid_transition, details}} =
             ProjectFSM.transition(state, :plan, %{}, storage: StorageStub)

    assert details.from == :objective
    assert details.to == :plan
    assert details.reason == :non_adjacent_transition
  end

  test "persists checkpoint metadata for each transition" do
    state = ProjectFSM.new("project-3", "session-3")

    assert {:ok, _next} =
             ProjectFSM.transition(state, :scope, %{objective: "Objective A"},
               storage: StorageStub
             )

    assert_receive {:checkpoint_saved, "session-3", checkpoint}, 1_000
    assert checkpoint.phase == "scope"
    assert checkpoint.project_id == "project-3"
    assert checkpoint.metadata.fsm_transition.from == "objective"
    assert checkpoint.metadata.fsm_transition.to == "scope"
  end

  test "derives wizard_phase cleanly from fsm_state across the full lifecycle" do
    s0 = ProjectFSM.new("project-4", "session-4")
    assert ProjectFSM.wizard_phase(s0) == :await_objective

    {:ok, s1} =
      ProjectFSM.transition(s0, :scope, %{objective: "Ship"}, storage: StorageStub)

    assert ProjectFSM.wizard_phase(s1) == :await_kind

    {:ok, s2} = ProjectFSM.set_kind(s1, :software)
    assert ProjectFSM.wizard_phase(s2) == :await_scope

    {:ok, s3} =
      ProjectFSM.transition(s2, :plan, %{scope: "core"}, storage: StorageStub)

    assert ProjectFSM.wizard_phase(s3) == :await_success

    {:ok, s4} = ProjectFSM.attach_plan(s3, "Tests green", %{kind: :software, items: []})
    assert ProjectFSM.wizard_phase(s4) == :ready

    {:ok, s5} =
      ProjectFSM.transition(s4, :execution, %{plan: s4.plan}, storage: StorageStub)

    assert ProjectFSM.wizard_phase(s5) == :ready

    {:ok, s6} =
      ProjectFSM.transition(s5, :review, %{execution: %{done: true}}, storage: StorageStub)

    assert ProjectFSM.wizard_phase(s6) == :ready

    {:ok, s7} =
      ProjectFSM.transition(s6, :delivery, %{review: %{approved: true}}, storage: StorageStub)

    assert ProjectFSM.wizard_phase(s7) == :ready
    assert ProjectFSM.wizard_phase(nil) == :unknown
  end

  test "validates set_kind/2 and attach_plan/3 preconditions" do
    s0 = ProjectFSM.new("project-5", "session-5")
    assert {:error, {:invalid_kind, _}} = ProjectFSM.set_kind(s0, :software)

    {:ok, s1} =
      ProjectFSM.transition(s0, :scope, %{objective: "Ship"}, storage: StorageStub)

    assert {:error, {:invalid_kind, _}} = ProjectFSM.set_kind(s1, :invalid_kind)

    {:ok, s2} = ProjectFSM.set_kind(s1, :non_software)
    assert {:error, {:invalid_plan, _}} = ProjectFSM.attach_plan(s2, "OK", %{items: []})

    {:ok, s3} =
      ProjectFSM.transition(s2, :plan, %{scope: "Brazil"}, storage: StorageStub)

    assert {:error, {:invalid_plan, _}} = ProjectFSM.attach_plan(s3, "   ", %{items: []})
    assert {:error, {:invalid_plan, _}} = ProjectFSM.attach_plan(s3, "OK", %{})
  end
end
