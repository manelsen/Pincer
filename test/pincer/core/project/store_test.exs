defmodule Pincer.Core.Project.StoreTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Project.Store

  test "persists and loads a project snapshot" do
    id = unique_id("p-store")
    session_id = unique_id("s-store")

    assert :ok =
             Store.save(%{
               id: id,
               session_id: session_id,
               kind: "server",
               status: :running,
               payload: %{objective: "Build it", active_task_index: 2}
             })

    assert {:ok, project} = Store.load(id)
    assert project.id == id
    assert project.session_id == session_id
    assert project.kind == "server"
    assert project.status == :running
    assert project.payload.active_task_index == 2

    assert :ok = Store.delete(id)
    assert {:error, :not_found} = Store.load(id)
  end

  test "lists projects by session, kind, and status" do
    session_id = unique_id("s-list")
    server_kind = unique_id("server")
    orchestrator_kind = unique_id("orchestrator")

    for {id, kind, status} <- [
          {unique_id("p-a"), server_kind, :running},
          {unique_id("p-b"), server_kind, :paused},
          {unique_id("p-c"), orchestrator_kind, :running}
        ] do
      assert :ok =
               Store.save(%{
                 id: id,
                 session_id: session_id,
                 kind: kind,
                 status: status,
                 payload: %{objective: id}
               })
    end

    assert {:ok, running_servers} =
             Store.list(session_id: session_id, kind: server_kind, status: [:running])

    assert length(running_servers) == 1
    assert hd(running_servers).status == :running
    assert hd(running_servers).kind == server_kind

    assert {:ok, all} = Store.list(session_id: session_id)
    assert length(all) == 3

    assert :ok = Store.delete_kind(server_kind)
    assert {:ok, remaining} = Store.list(session_id: session_id)
    assert Enum.all?(remaining, &(&1.kind == orchestrator_kind))
    assert :ok = Store.delete_kind(orchestrator_kind)
  end

  test "rejects invalid project status" do
    assert {:error, {:invalid_project_status, :bogus}} =
             Store.save(%{
               id: unique_id("p-bad"),
               session_id: unique_id("s-bad"),
               kind: "server",
               status: :bogus,
               payload: %{}
             })
  end

  test "consolidates orchestrator ETS cache and durable store operations" do
    session_id = unique_id("s-orch")
    table = :"test_orch_store_#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.delete_orchestrator_state(session_id, table) end)

    state = %{
      session_id: session_id,
      project_id: Store.build_project_id(session_id),
      phase: :ready,
      fsm_state: %{
        project_id: Store.build_project_id(session_id),
        session_id: session_id,
        phase: :execution,
        objective: "Ship",
        kind: :software,
        scope: "Core",
        success_criteria: "Green",
        plan: %{kind: :software, items: []},
        execution: nil,
        review: nil,
        delivery: nil
      },
      objective: "Ship",
      kind: :software,
      scope: "Core",
      success_criteria: "Green",
      items: [%{status: :in_progress, text: "Task 1"}],
      retry_count: 0,
      retry_limit: 0,
      git_branch: nil,
      git_branch_status: nil
    }

    saved = Store.put_orchestrator_state(state, table)
    assert saved.session_id == session_id
    refute Map.has_key?(saved, :phase)
    assert %{session_id: ^session_id} = Store.get_orchestrator_state(session_id, table)

    :ets.delete(table, session_id)

    loaded = Store.get_orchestrator_state(session_id, table)
    assert loaded.session_id == session_id
    refute Map.has_key?(loaded, :phase)
    assert [%{status: :pending, text: "Task 1"}] = loaded.items

    assert :ok = Store.delete_orchestrator_state(session_id, table)
    assert nil == Store.get_orchestrator_state(session_id, table)
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
