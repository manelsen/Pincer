defmodule Pincer.Core.Project.ServerDurabilityTest do
  use ExUnit.Case, async: false

  import Mox

  alias Pincer.Core.Project.Server
  alias Pincer.Core.Project.Store
  alias Pincer.Test.ProjectServer

  setup :set_mox_from_context

  setup do
    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn _msgs, _model, _config, _tools ->
      {:ok, %{"content" => "Tester: one task"}}
    end)
    |> stub(:stream_completion, fn _msgs, _model, _config, _tools ->
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "done"}}]}]}
    end)

    :ok
  end

  test "restores an awaiting-approval plan without replanning" do
    id = unique_id("p-restore")
    session_id = unique_id("s-restore")

    save(id, session_id, :awaiting_approval, %{
      objective: "Restored project",
      items: ["Tester: first", "Tester: second"],
      active_task_index: 0,
      retry_count: 0,
      max_retries: 3
    })

    {:ok, pid} = Server.start_link(id: id, session_id: session_id, objective: "ignored")
    on_exit(fn -> ProjectServer.stop(pid) end)
    on_exit(fn -> Store.delete(id) end)

    assert {:ok, state} = Server.get_status(id)
    assert state.status == :awaiting_approval
    assert state.items == ["Tester: first", "Tester: second"]
    assert state.objective == "Restored project"
  end

  test "stop persists a terminal stopped status" do
    id = unique_id("p-stop")
    session_id = unique_id("s-stop")

    save(id, session_id, :awaiting_approval, %{
      objective: "Stopped project",
      items: ["Tester: first"],
      active_task_index: 0,
      retry_count: 0,
      max_retries: 1
    })

    {:ok, _pid} = Server.start_link(id: id, session_id: session_id, objective: "ignored")
    on_exit(fn -> Store.delete(id) end)

    assert :ok = Server.stop(id)
    assert {:ok, state} = Server.get_status(id)
    assert state.status == :stopped
  end

  test "ensure_started rehydrates a paused project on demand" do
    id = unique_id("p-ensure")
    session_id = unique_id("s-ensure")

    save(id, session_id, :paused, %{
      objective: "Paused project",
      items: ["Tester: first"],
      active_task_index: 0,
      retry_count: 0,
      max_retries: 1
    })

    on_exit(fn -> Store.delete(id) end)

    assert {:ok, pid} = Server.ensure_started(id)
    assert is_pid(pid)
    assert {:ok, %{status: :paused}} = Server.get_status(id)
    assert :ok = Server.stop(id)
  end

  test "a persisted running project resumes execution from its task index" do
    id = unique_id("p-resume")
    session_id = unique_id("s-resume")

    save(id, session_id, :running, %{
      objective: "Resuming project",
      items: ["Tester: one task"],
      active_task_index: 0,
      retry_count: 0,
      max_retries: 1
    })

    {:ok, pid} = Server.start_link(id: id, session_id: session_id, objective: "ignored")
    on_exit(fn -> ProjectServer.stop(pid) end)
    on_exit(fn -> Store.delete(id) end)

    assert wait_until(fn ->
             case Server.get_status(id) do
               {:ok, %{status: status}} when status in [:running, :completed] -> true
               _ -> false
             end
           end)
  end

  defp save(id, session_id, status, payload) do
    assert :ok =
             Store.save(%{
               id: id,
               session_id: session_id,
               kind: "server",
               status: status,
               payload: Map.merge(%{id: id, session_id: session_id}, payload)
             })
  end

  defp wait_until(predicate, attempts \\ 50) do
    cond do
      predicate.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && wait_until(predicate, attempts - 1)
    end
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
