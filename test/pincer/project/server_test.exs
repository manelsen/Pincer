defmodule Pincer.Core.Project.ServerTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Core.Project.Server
  alias Pincer.Core.Orchestration.Blackboard

  setup :set_mox_from_context

  setup do
    Application.put_env(:pincer, :llm_providers, %{
      "test" => %{
        adapter: Pincer.LLM.ClientMock,
        base_url: "http://mock",
        default_model: "test-model",
        env_key: "MOCK_KEY"
      }
    })

    Application.put_env(:pincer, :default_llm_provider, "test")

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
    on_exit(fn -> if Process.alive?(pid), do: Server.stop(id) end)

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
    on_exit(fn -> if Process.alive?(pid), do: Server.stop(id) end)

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
