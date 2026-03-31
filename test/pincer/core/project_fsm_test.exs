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
end
