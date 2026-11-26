defmodule Pincer.Core.Project.PlanTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Project.Plan

  defmodule GitCreatedStub do
    def ensure_branch(name), do: {:ok, %{name: name, status: :created}}
  end

  defmodule GitErrorStub do
    def ensure_branch(_name), do: {:error, {:not_a_repository, "not a git repo"}}
  end

  defp ready_state(kind \\ :software) do
    %{
      session_id: "plan-session-1",
      project_id: "project-plan-session-1",
      fsm_state: %{
        project_id: "project-plan-session-1",
        session_id: "plan-session-1",
        phase: :plan,
        objective: "Build feature",
        kind: kind,
        scope: "Core",
        success_criteria: "All tests pass",
        plan: %{kind: kind, items: [%{status: :pending, text: "Step 1"}]},
        execution: nil,
        review: nil,
        delivery: nil
      },
      objective: "Build feature",
      kind: kind,
      scope: "Core",
      success_criteria: "All tests pass",
      items: [],
      retry_count: 0,
      retry_limit: 1,
      git_branch: nil,
      git_branch_status: nil
    }
  end

  test "builds software and non_software items" do
    software_items = Plan.build_items(%{kind: :software, objective: "Obj", scope: "Scope"})
    assert length(software_items) == 6
    assert Enum.all?(software_items, &(&1.status == :pending))
    assert Enum.any?(software_items, &(&1.text =~ "Red"))

    non_sw_items = Plan.build_items(%{kind: :non_software, objective: "Obj", scope: "Scope"})
    assert length(non_sw_items) == 5
    refute Enum.any?(non_sw_items, &(&1.text =~ "DDD"))
  end

  test "prepare/3 populates items and ensures git branch via adapter" do
    state = ready_state(:software)

    {prepared, plan_payload} =
      Plan.prepare(state, "Green suite", git: GitCreatedStub, retry_limit: 2)

    assert length(prepared.items) == 6
    assert prepared.git_branch =~ "project/build-feature-"
    assert prepared.git_branch_status == :created
    assert prepared.retry_limit == 2
    assert plan_payload.kind == :software
    assert length(plan_payload.items) == 6

    {errored, _} = Plan.prepare(state, "Green suite", git: GitErrorStub)
    assert errored.git_branch_status == {:error, {:not_a_repository, "not a git repo"}}
  end

  test "execution task transitions: start_next_task, complete_current_task, fail_current_task" do
    state = %{
      ready_state()
      | items: [%{status: :pending, text: "T1"}, %{status: :pending, text: "T2"}]
    }

    assert {:started, s1, "T1"} = Plan.start_next_task(state)
    assert :already_started = Plan.start_next_task(s1)

    assert {:retry, s2, "T1", 1} = Plan.fail_current_task(s1)
    assert {:paused, s3, "T1"} = Plan.fail_current_task(s2)
    assert Enum.all?(s3.items, &(&1.status == :pending))

    assert {:started, s4, "T1"} = Plan.start_next_task(s3)
    assert {:next, s5, "T1", "T2"} = Plan.complete_current_task(s4)
    assert {:all_done, s6, "T2"} = Plan.complete_current_task(s5)
    assert Enum.all?(s6.items, &(&1.status == :done))
    assert :completed = Plan.start_next_task(s6)
  end
end
