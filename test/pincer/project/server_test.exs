defmodule Pincer.Core.Project.ServerTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Core.Project.Server
  alias Pincer.Core.Orchestration.Blackboard

  setup :set_mox_from_context

  setup do
    # Inicia o Blackboard se não estiver rodando
    case Process.whereis(Blackboard) do
      nil -> Blackboard.start_link([])
      _ -> :ok
    end

    :ok
  end

  test "Project.Server starts and transitions to awaiting_approval" do
    Pincer.LLM.ClientMock
    |> expect(:chat_completion, fn _msgs, _model, _config, _tools ->
      {:ok, %{"content" => "Architect: Spec\nTester: Red"}}
    end)

    id = "p-test-1"
    {:ok, _pid} = Server.start_link(id: id, session_id: "s1", objective: "Objective 1")

    wait_for_status(id, :awaiting_approval)

    {:ok, state} = Server.get_status(id)
    assert state.status == :awaiting_approval
  end

  test "Project.Server handles approval and task execution" do
    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn _msgs, _model, _config, _tools ->
      {:ok, %{"content" => "Tester: RED"}}
    end)

    id = "p-test-2"
    {:ok, _pid} = Server.start_link(id: id, session_id: "s2", objective: "Task Test")

    wait_for_status(id, :awaiting_approval)
    Server.approve(id)

    Process.sleep(100)
    {:ok, state} = Server.get_status(id)
    assert state.status in [:running, :completed]
  end

  defp wait_for_status(id, target_status, attempts \\ 10) do
    if attempts == 0 do
      flunk("Timeout waiting for status #{target_status} for project #{id}")
    else
      case Server.get_status(id) do
        {:ok, %{status: ^target_status}} ->
          :ok

        _ ->
          Process.sleep(100)
          wait_for_status(id, target_status, attempts - 1)
      end
    end
  end
end
