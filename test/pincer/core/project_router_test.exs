defmodule Pincer.Core.ProjectGitStubRouter do
  @moduledoc false

  def ensure_branch(name) do
    {:ok, %{name: name, status: :created, source_branch: "sprint/spr-080"}}
  end
end

defmodule Pincer.Core.ProjectRouterTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.ProjectOrchestrator
  alias Pincer.Core.ProjectRouter

  setup do
    previous = Application.get_env(:pincer, :project_git)
    Application.put_env(:pincer, :project_git, Pincer.Core.ProjectGitStubRouter)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:pincer, :project_git)
        module -> Application.put_env(:pincer, :project_git, module)
      end

      ProjectOrchestrator.reset_all()
    end)

    :ok
  end

  test "project/2 starts the wizard and continue_if_collecting/3 advances it" do
    session_id = unique_session_id()
    response = ProjectRouter.project(session_id)
    assert response =~ "Project Manager"

    assert {:handled, next} =
             ProjectRouter.continue_if_collecting(session_id, "Pesquisar parafusadeiras")

    assert next =~ "tipo do projeto"
  end

  test "continue_if_collecting/3 ignores messages with attachments" do
    session_id = unique_session_id()
    _ = ProjectRouter.project(session_id)

    assert :not_handled ==
             ProjectRouter.continue_if_collecting(session_id, "texto", has_attachments: true)
  end

  test "kanban/1 falls back to global board when no project is ready" do
    session_id = unique_session_id()
    board = ProjectRouter.kanban(session_id)
    assert board =~ "Kanban Board"
  end

  defp unique_session_id do
    "project_router_#{System.unique_integer([:positive])}"
  end
end
