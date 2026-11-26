defmodule Pincer.Core.Project.WizardTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Project.Wizard
  alias Pincer.Core.ProjectFSM

  defp base_state do
    %{
      session_id: "wiz-s1",
      project_id: "project-wiz-s1",
      fsm_state: ProjectFSM.new("project-wiz-s1", "wiz-s1"),
      objective: nil,
      kind: nil,
      scope: nil,
      success_criteria: nil,
      items: [],
      retry_count: 0,
      retry_limit: 0,
      git_branch: nil,
      git_branch_status: nil
    }
  end

  describe "phase/1 and collecting?/1" do
    test "derives collection phases strictly from fsm_state" do
      state = base_state()
      assert Wizard.phase(state) == :await_objective
      assert Wizard.collecting?(state)

      {:ok, fsm_scope} =
        ProjectFSM.transition(state.fsm_state, :scope, %{objective: "Build X"},
          storage: Pincer.Core.ProjectOrchestrator.NoopFSMStorage
        )

      state_kind = %{state | fsm_state: fsm_scope, objective: "Build X"}
      assert Wizard.phase(state_kind) == :await_kind
      assert Wizard.collecting?(state_kind)

      {:ok, fsm_with_kind} = ProjectFSM.set_kind(fsm_scope, :software)
      state_scope = %{state_kind | fsm_state: fsm_with_kind, kind: :software}
      assert Wizard.phase(state_scope) == :await_scope
      assert Wizard.collecting?(state_scope)

      {:ok, fsm_plan} =
        ProjectFSM.transition(fsm_with_kind, :plan, %{scope: "Core"},
          storage: Pincer.Core.ProjectOrchestrator.NoopFSMStorage
        )

      state_success = %{state_scope | fsm_state: fsm_plan, scope: "Core"}
      assert Wizard.phase(state_success) == :await_success
      assert Wizard.collecting?(state_success)

      {:ok, fsm_ready} =
        ProjectFSM.attach_plan(fsm_plan, "Tests green", %{kind: :software, items: []})

      state_ready = %{state_success | fsm_state: fsm_ready, success_criteria: "Tests green"}
      assert Wizard.phase(state_ready) == :ready
      refute Wizard.collecting?(state_ready)
    end
  end

  describe "parse_kind/1" do
    test "parses software and non-software variants including accents" do
      assert {:ok, :software} == Wizard.parse_kind("software")
      assert {:ok, :software} == Wizard.parse_kind("API backend em Elixir")
      assert {:ok, :non_software} == Wizard.parse_kind("nao-software")
      assert {:ok, :non_software} == Wizard.parse_kind("E um projeto n\u00E3o-software")
      assert :error == Wizard.parse_kind("talvez")
      assert :error == Wizard.parse_kind("   ")
    end
  end

  describe "step/2" do
    test "returns pure step intents for each wizard phase" do
      state = base_state()
      assert {:transition, :scope, %{objective: "Ship"}, prompt} = Wizard.step(state, "  Ship  ")
      assert prompt =~ "Objetivo registrado: Ship"

      {:ok, fsm_scope} =
        ProjectFSM.transition(state.fsm_state, :scope, %{objective: "Ship"},
          storage: Pincer.Core.ProjectOrchestrator.NoopFSMStorage
        )

      state_kind = %{state | fsm_state: fsm_scope, objective: "Ship"}
      assert {:noop, ^state_kind, retry_prompt} = Wizard.step(state_kind, "unknown")
      assert retry_prompt =~ "Responda com `software` ou `nao-software`"

      assert {:set_kind, :non_software, scope_prompt} = Wizard.step(state_kind, "nao-software")
      assert scope_prompt =~ "contexto e escopo da pesquisa"

      {:ok, fsm_with_kind} = ProjectFSM.set_kind(fsm_scope, :non_software)
      state_scope = %{state_kind | fsm_state: fsm_with_kind, kind: :non_software}

      assert {:transition, :plan, %{scope: "Brazil"}, success_prompt} =
               Wizard.step(state_scope, "Brazil")

      assert success_prompt =~ "ranking final com evidencias"

      {:ok, fsm_plan} =
        ProjectFSM.transition(fsm_with_kind, :plan, %{scope: "Brazil"},
          storage: Pincer.Core.ProjectOrchestrator.NoopFSMStorage
        )

      state_success = %{state_scope | fsm_state: fsm_plan, scope: "Brazil"}

      assert {:finalize_plan, "Top 3"} = Wizard.step(state_success, "Top 3")
    end
  end
end
