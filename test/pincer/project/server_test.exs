defmodule Pincer.Core.Project.ServerTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Core.Project.Server
  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Test.ProjectServer
  alias Pincer.Test.Support.LLMHelpers
  alias Pincer.Test.Support.SyncHelpers

  setup :set_mox_from_context

  setup do
    LLMHelpers.put_providers!(
      %{"test" => LLMHelpers.mock_provider_config()},
      default: "test"
    )

    # Inicia o Blackboard se não estiver rodando
    case Process.whereis(Blackboard) do
      nil -> Blackboard.start_link([])
      _ -> :ok
    end

    :ok
  end

  test "Project.Server starts and transitions to awaiting_approval" do
    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn _msgs, _model, _config, _tools ->
      {:ok, %{"content" => "Architect: Spec\nTester: Red"}}
    end)
    |> stub(:stream_completion, fn _msgs, _model, _config, _tools ->
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "Tester: Red"}}]}]}
    end)

    id = "p-awaiting-#{System.unique_integer([:positive])}"
    {:ok, pid} = Server.start_link(id: id, session_id: "s1", objective: "Objective 1")
    on_exit(fn -> ProjectServer.stop(pid) end)

    wait_for_status(id, :awaiting_approval)

    {:ok, state} = Server.get_status(id)
    assert state.status == :awaiting_approval
  end

  test "Project.Server handles approval and task execution" do
    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn _msgs, _model, _config, _tools ->
      {:ok, %{"content" => "Tester: RED"}}
    end)
    |> stub(:stream_completion, fn _msgs, _model, _config, _tools ->
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "Tester: RED"}}]}]}
    end)

    id = "p-approval-#{System.unique_integer([:positive])}"
    {:ok, pid} = Server.start_link(id: id, session_id: "s2", objective: "Task Test")
    on_exit(fn -> ProjectServer.stop(pid) end)

    wait_for_status(id, :awaiting_approval)
    Server.approve(id)

    state =
      SyncHelpers.eventually(fn ->
        case Server.get_status(id) do
          {:ok, %{status: status} = state} when status in [:running, :completed] -> state
          _ -> nil
        end
      end)

    assert state.status in [:running, :completed]
  end

  defp wait_for_status(id, target_status) do
    SyncHelpers.eventually(
      fn -> match?({:ok, %{status: ^target_status}}, Server.get_status(id)) end,
      timeout: 1_000,
      interval: 10,
      message: "Timeout waiting for status #{target_status} for project #{id}"
    )
  end
end
