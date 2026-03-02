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

defmodule Pincer.Core.ProjectGitStubNotRepo do
  @moduledoc false

  def ensure_branch(_name) do
    {:error, {:not_a_repository, "fatal: not a git repository"}}
  end
end

defmodule Pincer.Core.ProjectOrchestratorTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.ProjectOrchestrator

  setup do
    previous = Application.get_env(:pincer, :project_git)
    previous_retry_limit = Application.get_env(:pincer, :project_task_retry_limit)
    Application.put_env(:pincer, :project_git, Pincer.Core.ProjectGitStubSuccess)
    Application.put_env(:pincer, :project_task_retry_limit, 1)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pincer, :project_git)
        module -> Application.put_env(:pincer, :project_git, module)
      end

      case previous_retry_limit do
        nil -> Application.delete_env(:pincer, :project_task_retry_limit)
        value -> Application.put_env(:pincer, :project_task_retry_limit, value)
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

    test "accepts accented non-software answer and keeps research prompts" do
      session_id = unique_session_id()
      on_exit(fn -> ProjectOrchestrator.reset(session_id) end)

      assert ProjectOrchestrator.start(session_id) =~ "Project Manager"

      assert {:handled, _} =
               ProjectOrchestrator.continue(session_id, "Comparar politicas empresariais")

      assert {:handled, response_scope} =
               ProjectOrchestrator.continue(session_id, "E um projeto n\u00E3o-software")

      assert response_scope =~ "contexto e escopo da pesquisa"
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
      assert completed =~ "git branch project/"
      refute completed =~ "git checkout -b project/"
    end

    test "renders git bootstrap flow when current path is not a repository" do
      session_id = unique_session_id()
      on_exit(fn -> ProjectOrchestrator.reset(session_id) end)
      Application.put_env(:pincer, :project_git, Pincer.Core.ProjectGitStubNotRepo)

      assert ProjectOrchestrator.start(session_id) =~ "Project Manager"

      assert {:handled, _} =
               ProjectOrchestrator.continue(session_id, "Pesquisar regulacao corporativa")

      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "nao-software")
      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Internet aberta")

      assert {:handled, completed} =
               ProjectOrchestrator.continue(
                 session_id,
                 "Relatorio comparativo com evidencias"
               )

      assert completed =~ "Ambiente atual nao e um repositorio Git"
      assert completed =~ "git init"
      assert completed =~ "git branch project/"
      refute completed =~ "git checkout -b project/"
    end
  end

  describe "execution recovery" do
    test "retries active task and pauses after retry budget is exhausted" do
      session_id = unique_session_id()
      on_exit(fn -> ProjectOrchestrator.reset(session_id) end)

      assert ProjectOrchestrator.start(session_id) =~ "Project Manager"
      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Pesquisa de mercado")
      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "nao-software")
      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Brasil, internet aberta")
      assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Relatorio comparativo")

      assert {:ok, kickoff} = ProjectOrchestrator.kickoff(session_id)
      assert kickoff.status_message =~ "Task started"

      assert {:retry, retry_progress} = ProjectOrchestrator.on_agent_error(session_id)
      assert retry_progress.status_message =~ "Task retrying (1/1)"
      assert retry_progress.prompt =~ "PROJECT TASK"

      assert {:ok, board_after_retry} = ProjectOrchestrator.board(session_id)
      assert board_after_retry =~ "Done: 0 | In Progress: 1 | Pending: 4"

      assert {:paused, paused_progress} = ProjectOrchestrator.on_agent_error(session_id)
      assert paused_progress.status_message =~ "Task paused after 1 retries"
      assert paused_progress.status_message =~ "/project"

      assert {:ok, board_after_pause} = ProjectOrchestrator.board(session_id)
      assert board_after_pause =~ "Done: 0 | In Progress: 0 | Pending: 5"

      assert {:ok, resumed} = ProjectOrchestrator.kickoff(session_id)
      assert resumed.task =~ "Architect:"
      assert resumed.status_message =~ "Task started"
    end
  end

  defp unique_session_id do
    "project_orch_#{System.unique_integer([:positive])}"
  end
end
