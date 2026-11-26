defmodule Pincer.Core.Project.RendererTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Project.Renderer

  test "renders software and non_software ready messages with git summary" do
    sw_state = %{
      project_id: "project-1",
      objective: "Evoluir /project",
      kind: :software,
      scope: "Telegram",
      success_criteria: "Testes verdes",
      items: [%{status: :pending, text: "Architect: spec"}],
      git_branch: "project/evoluir-1",
      git_branch_status: :created
    }

    msg = Renderer.render_ready_message(sw_state)
    assert msg =~ "Project plan initialized"
    assert msg =~ "Flow: Architect -> Coder -> Reviewer (DDD/TDD ativo)"
    assert msg =~ "git checkout project/evoluir-1"

    non_sw = %{
      sw_state
      | kind: :non_software,
        git_branch_status: {:error, {:not_a_repository, "no repo"}}
    }

    non_sw_msg = Renderer.render_ready_message(non_sw)
    assert non_sw_msg =~ "Flow: Architect -> Coder -> Reviewer (Research/Validation)"
    assert non_sw_msg =~ "git init"
    refute non_sw_msg =~ "DDD/TDD"
  end

  test "renders kanban board with counts and max_items limit" do
    state = %{
      objective: "Board test",
      kind: :software,
      items: [
        %{status: :done, text: "Done 1"},
        %{status: :in_progress, text: "Active 1"},
        %{status: :pending, text: "Pending 1"},
        %{status: :pending, text: "Pending 2"}
      ]
    }

    board = Renderer.render_board(state, max_items: 1)
    assert board =~ "Kanban Board"
    assert board =~ "Done: 1 | In Progress: 1 | Pending: 2"
    assert board =~ "Pending (Top 1)"
    assert board =~ "- Pending 1"
    refute board =~ "- Pending 2"
    assert board =~ "Flow DDD/TDD"
  end

  test "renders task prompt using fsm_state phase" do
    state = %{
      project_id: "project-9",
      objective: "Ship",
      fsm_state: %{phase: :execution}
    }

    prompt = Renderer.build_task_prompt(state, "Implement X")
    assert prompt =~ "Project ID: project-9"
    assert prompt =~ "Phase: execution"
    assert prompt =~ "Objective: Ship"
    assert prompt =~ "Task: Implement X"
  end
end
