defmodule Pincer.Core.ProjectGitStubSuccess do
  @moduledoc false

  def ensure_branch(name) do
    {:ok, %{name: name, status: :created, source_branch: "sprint/spr-080"}}
  end
end

defmodule Pincer.Core.ProjectGitStubFailure do
  @moduledoc false

  def ensure_branch(_name) do
    {:error, {:branch_create_failed, "permission denied"}}
  end
end

defmodule Pincer.Core.ProjectOrchestratorTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.ProjectOrchestrator

  setup do
    previous = Application.get_env(:pincer, :project_git)
    Application.put_env(:pincer, :project_git, Pincer.Core.ProjectGitStubSuccess)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pincer, :project_git)
        module -> Application.put_env(:pincer, :project_git, module)
      end

      ProjectOrchestrator.reset_all()
    end)

    :ok
  end

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
      assert completed =~ "**Git Branch**"
      assert completed =~ "git checkout project/"
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

    test "keeps project flow alive when branch creation fails" do
      session_id = unique_session_id()
      on_exit(fn -> ProjectOrchestrator.reset(session_id) end)
      Application.put_env(:pincer, :project_git, Pincer.Core.ProjectGitStubFailure)

      assert ProjectOrchestrator.start(session_id) =~ "Project Manager"
      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Pesquisar parafusadeiras")
      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "nao-software")
      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Belo Horizonte")

      assert {:handled, completed} =
               ProjectOrchestrator.continue(
                 session_id,
                 "Definir recomendacao com evidencias"
               )

      assert completed =~ "Project plan initialized"
      assert completed =~ "Falha ao preparar branch automaticamente"
      assert completed =~ "git checkout -b project/"
    end
  end

  defp unique_session_id do
    "project_orch_#{System.unique_integer([:positive])}"
  end
end
