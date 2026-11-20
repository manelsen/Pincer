defmodule Pincer.Core.Project.DiagnosticTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Core.LLM.CooldownStore
  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Core.Project.Server

  setup :set_mox_from_context

  setup do
    original_providers = Application.get_env(:pincer, :llm_providers)
    original_default = Application.get_env(:pincer, :default_llm_provider)

    Application.put_env(:pincer, :llm_providers, %{
      "test" => %{
        adapter: Pincer.LLM.ClientMock,
        base_url: "http://mock",
        default_model: "test-model",
        env_key: "MOCK_KEY"
      }
    })

    Application.put_env(:pincer, :default_llm_provider, "test")

    case Process.whereis(Blackboard) do
      nil -> Blackboard.start_link([])
      _ -> :ok
    end

    Blackboard.reset()
    CooldownStore.reset()

    on_exit(fn ->
      Application.put_env(:pincer, :llm_providers, original_providers)
      Application.put_env(:pincer, :default_llm_provider, original_default)
      CooldownStore.reset()
    end)

    :ok
  end

  test "Generates ERROR_DIAGNOSTIC when max_retries is reached" do
    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn
      [%{"role" => "system", "content" => "You are the Pincer PROJECT ARCHITECT" <> _}],
      _model,
      _config,
      _tools ->
        {:ok, %{"content" => "Coder: Fail this task"}}

      _msgs, _model, _config, _tools ->
        {:error, :rate_limit_exceeded}
    end)
    |> stub(:stream_completion, fn _msgs, _model, _config, _tools ->
      {:error, :rate_limit_exceeded}
    end)

    id = "p-fail-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Server.start_link(
        id: id,
        session_id: "s-diag",
        objective: "Diagnostic test",
        max_retries: 1
      )

    on_exit(fn -> if Process.alive?(pid), do: Server.stop(id) end)

    wait_for_status(id, :awaiting_approval)
    Server.approve(id)

    wait_for_status(id, :error)

    {messages, _} = Blackboard.fetch_new(0, scope: :all)

    diagnostic_msg =
      Enum.find(messages, fn m -> String.contains?(m.content, "ERROR_DIAGNOSTIC") end)

    assert diagnostic_msg != nil
    assert diagnostic_msg.project_id == id
    assert String.contains?(diagnostic_msg.content, "Task failed after")
    assert String.contains?(diagnostic_msg.content, ":rate_limit_exceeded")
  end

  test "ignores stale ref error messages without transitioning status" do
    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn _msgs, _model, _config, _tools ->
      {:ok, %{"content" => "Coder: Succeed later"}}
    end)

    id = "p-stale-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Server.start_link(
        id: id,
        session_id: "s-stale",
        objective: "Stale ref test",
        max_retries: 1
      )

    on_exit(fn -> if Process.alive?(pid), do: Server.stop(id) end)

    wait_for_status(id, :awaiting_approval)

    stale_ref = make_ref()
    send(pid, {stale_ref, {:error, :stale_reason}})
    send(pid, {:executor_failed, :legacy_reason})
    send(pid, {:DOWN, stale_ref, :process, self(), :killed})

    {:ok, state} = Server.get_status(id)
    assert state.status == :awaiting_approval
    assert state.retry_count == 0
    assert state.last_error == nil
  end

  defp wait_for_status(id, target_status, attempts \\ 20) do
    if attempts == 0 do
      flunk("Timeout waiting for status #{target_status}")
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
