defmodule Pincer.Core.ProjectOrchestratorTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ProjectOrchestrator

  describe "project wizard flow" do
    test "starts wizard asking for objective" do
      session_id = unique_session_id()
      on_exit(fn -> ProjectOrchestrator.reset(session_id) end)

      response = ProjectOrchestrator.start(session_id)

      assert response =~ "Project Manager"
      assert response =~ "Qual e o objetivo principal?"
      assert ProjectOrchestrator.collecting?(session_id)
    end

    test "builds non-software plan without DDD/TDD language" do
      session_id = unique_session_id()
      on_exit(fn -> ProjectOrchestrator.reset(session_id) end)

      assert ProjectOrchestrator.start(session_id) =~ "Project Manager"

      assert {:handled, response_kind} =
               ProjectOrchestrator.continue(session_id, "Comprar parafusadeira")

      assert response_kind =~ "tipo do projeto"

      assert {:handled, response_scope} = ProjectOrchestrator.continue(session_id, "nao-software")
      assert response_scope =~ "contexto e escopo da pesquisa"

      assert {:handled, response_success} =
               ProjectOrchestrator.continue(
                 session_id,
                 "Belo Horizonte, ate 600 reais, foco em bateria"
               )

      assert response_success =~ "criterio de sucesso"

      assert {:handled, completed} =
               ProjectOrchestrator.continue(
                 session_id,
                 "Receber top 3 com preco, loja e recomendacao final"
               )

      assert completed =~ "Project plan initialized"
      assert completed =~ "Architect"
      assert completed =~ "Coder"
      assert completed =~ "Reviewer"
      refute completed =~ "DDD/TDD"

      assert {:ok, board} = ProjectOrchestrator.board(session_id)
      assert board =~ "Kanban Board"
      assert board =~ "Flow Research/Validation"
      refute board =~ "Spec -> Contract -> Red"
      refute ProjectOrchestrator.collecting?(session_id)
      assert :not_active == ProjectOrchestrator.continue(session_id, "qualquer texto")
    end

    test "builds software plan with DDD/TDD flow in kanban" do
      session_id = unique_session_id()
      on_exit(fn -> ProjectOrchestrator.reset(session_id) end)

      assert ProjectOrchestrator.start(session_id) =~ "Project Manager"
      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Evoluir comando /project")
      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "software")
      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Telegram e Discord")

      assert {:handled, completed} =
               ProjectOrchestrator.continue(
                 session_id,
                 "Testes verdes com orientacao explicita e roteamento por sessao"
               )

      assert completed =~ "Flow: Architect -> Coder -> Reviewer (DDD/TDD ativo)"

      assert {:ok, board} = ProjectOrchestrator.board(session_id, max_items: 3)
      assert board =~ "Kanban Board"
      assert board =~ "Flow DDD/TDD"
      assert board =~ "Spec -> Contract -> Red -> Green -> Refactor -> Review -> Done"
    end
  end

  defp unique_session_id do
    "project_orch_#{System.unique_integer([:positive])}"
  end
end
