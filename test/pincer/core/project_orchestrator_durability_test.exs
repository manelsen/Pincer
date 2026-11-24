defmodule Pincer.Core.ProjectOrchestratorDurabilityTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.ProjectOrchestrator

  defmodule GitStub do
    @moduledoc false
    def ensure_branch(name), do: {:ok, %{name: name, status: :created}}
  end

  setup do
    previous_git = Application.get_env(:pincer, :project_git)
    Application.put_env(:pincer, :project_git, GitStub)

    on_exit(fn ->
      case previous_git do
        nil -> Application.delete_env(:pincer, :project_git)
        module -> Application.put_env(:pincer, :project_git, module)
      end
    end)

    :ok
  end

  test "reloads a completed wizard from durable storage after ETS loss" do
    session_id = unique_session_id()
    on_exit(fn -> ProjectOrchestrator.reset(session_id) end)

    assert ProjectOrchestrator.start(session_id) =~ "Project Manager"
    assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Pesquisa de mercado")
    assert {:handled, _} = ProjectOrchestrator.continue(session_id, "nao-software")
    assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Brasil")
    assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Relatorio final")

    assert {:ok, board} = ProjectOrchestrator.board(session_id)
    assert board =~ "Kanban Board"

    drop_ets_state(session_id)

    assert {:ok, restored_board} = ProjectOrchestrator.board(session_id)
    assert restored_board == board
  end

  test "an in-flight task becomes pending again after a reload" do
    session_id = unique_session_id()
    on_exit(fn -> ProjectOrchestrator.reset(session_id) end)

    assert ProjectOrchestrator.start(session_id) =~ "Project Manager"
    assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Pesquisa de mercado")
    assert {:handled, _} = ProjectOrchestrator.continue(session_id, "nao-software")
    assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Brasil")
    assert {:handled, _} = ProjectOrchestrator.continue(session_id, "Relatorio final")

    assert {:ok, kickoff} = ProjectOrchestrator.kickoff(session_id)
    assert kickoff.task =~ "Architect:"

    drop_ets_state(session_id)

    assert {:ok, resumed} = ProjectOrchestrator.kickoff(session_id)
    assert resumed.task == kickoff.task
    assert resumed.status_message =~ "Task started"
  end

  defp drop_ets_state(session_id) do
    :ets.delete(Pincer.Core.ProjectOrchestrator, session_id)
  rescue
    ArgumentError -> :ok
  end

  defp unique_session_id do
    "project_orch_durable_#{System.unique_integer([:positive])}"
  end
end
