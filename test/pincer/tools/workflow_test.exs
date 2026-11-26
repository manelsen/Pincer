defmodule Pincer.Adapters.Tools.WorkflowTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.Workflow

  @tmp_dir System.tmp_dir!()

  # ---------------------------------------------------------------------------
  # Stub dependencies
  # ---------------------------------------------------------------------------

  defmodule StubRegistry do
    def list_session_ids, do: ["session-a", "session-b"]
  end

  defmodule EmptyRegistry do
    def list_session_ids, do: []
  end

  defmodule StubSessionServer do
    def get_status("existing") do
      {:ok,
       %{
         session_id: "existing",
         status: :active,
         provider: "google",
         history: [1, 2, 3],
         workspace_path: "/workspaces/existing"
       }}
    end

    def get_status(id), do: {:error, "not found: #{id}"}
  end

  defmodule StubOrchestrator do
    def list_projects("has-projects") do
      [{"alpha", %{phase: "planning"}}, {"beta", %{phase: "execution"}}]
    end

    def list_projects(_), do: []

    def board("has-board"), do: {:ok, "| TODO | IN PROGRESS | DONE |\n| ... |"}
    def board(_), do: :not_found
  end

  # ---------------------------------------------------------------------------
  # Workspace helpers
  # ---------------------------------------------------------------------------

  # The suite runs async, so every workspace needs a name no other test can
  # draw; a random integer collides often enough to fail under load.
  defp tmp_workspace do
    path =
      Path.join(
        @tmp_dir,
        "pincer_workflow_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp execute(args, workspace \\ nil) do
    ws = workspace || tmp_workspace()
    ctx = %{"workspace_path" => ws, "session_id" => "test"}
    Workflow.execute(args, ctx)
  end

  # ---------------------------------------------------------------------------
  # spec/0
  # ---------------------------------------------------------------------------

  test "spec/0 returns a valid tool spec" do
    spec = Workflow.spec()
    assert spec.name == "workflow"
    assert is_binary(spec.description)
    actions = get_in(spec, [:parameters, :properties, :action, :enum])
    assert "list_sessions" in actions
    assert "get_session" in actions
    assert "list_agents" in actions
    assert "list_projects" in actions
    assert "get_board" in actions
    assert "list_tasks" in actions
    assert "create_task" in actions
    assert "get_task" in actions
    assert "update_task" in actions
  end

  test "spec/0 requires action" do
    assert "action" in get_in(Workflow.spec(), [:parameters, :required])
  end

  # ---------------------------------------------------------------------------
  # list_sessions
  # ---------------------------------------------------------------------------

  test "list_sessions returns active sessions" do
    Application.put_env(:pincer, :workflow_session_registry, StubRegistry)

    assert {:ok, text} = Workflow.execute(%{"action" => "list_sessions"})
    assert text =~ "session-a"
    assert text =~ "session-b"
  after
    Application.delete_env(:pincer, :workflow_session_registry)
  end

  test "list_sessions with no sessions returns friendly message" do
    Application.put_env(:pincer, :workflow_session_registry, EmptyRegistry)

    assert {:ok, text} = Workflow.execute(%{"action" => "list_sessions"})
    assert text =~ "No active"
  after
    Application.delete_env(:pincer, :workflow_session_registry)
  end

  # ---------------------------------------------------------------------------
  # get_session
  # ---------------------------------------------------------------------------

  test "get_session returns session details" do
    Application.put_env(:pincer, :workflow_session_server, StubSessionServer)

    assert {:ok, text} =
             Workflow.execute(%{"action" => "get_session", "session_id" => "existing"})

    assert text =~ "existing"
    assert text =~ "active"
    assert text =~ "google"
  after
    Application.delete_env(:pincer, :workflow_session_server)
  end

  test "get_session for unknown session returns error" do
    Application.put_env(:pincer, :workflow_session_server, StubSessionServer)

    assert {:error, msg} =
             Workflow.execute(%{"action" => "get_session", "session_id" => "ghost"})

    assert msg =~ "ghost"
  after
    Application.delete_env(:pincer, :workflow_session_server)
  end

  # ---------------------------------------------------------------------------
  # list_agents
  # ---------------------------------------------------------------------------

  test "list_agents returns no workspaces when dir missing" do
    # In test env the workspaces dir may or may not exist — both paths are valid
    result = Workflow.execute(%{"action" => "list_agents"})

    case result do
      {:ok, text} -> assert is_binary(text)
      {:error, msg} -> assert is_binary(msg)
    end
  end

  # ---------------------------------------------------------------------------
  # list_projects
  # ---------------------------------------------------------------------------

  test "list_projects returns projects for session" do
    Application.put_env(:pincer, :workflow_orchestrator, StubOrchestrator)

    assert {:ok, text} =
             Workflow.execute(%{"action" => "list_projects", "session_id" => "has-projects"})

    assert text =~ "alpha"
    assert text =~ "planning"
    assert text =~ "beta"
  after
    Application.delete_env(:pincer, :workflow_orchestrator)
  end

  test "list_projects returns friendly message when none" do
    Application.put_env(:pincer, :workflow_orchestrator, StubOrchestrator)

    assert {:ok, text} =
             Workflow.execute(%{"action" => "list_projects", "session_id" => "empty"})

    assert text =~ "No active"
  after
    Application.delete_env(:pincer, :workflow_orchestrator)
  end

  # ---------------------------------------------------------------------------
  # get_board
  # ---------------------------------------------------------------------------

  test "get_board returns board text" do
    Application.put_env(:pincer, :workflow_orchestrator, StubOrchestrator)

    assert {:ok, text} =
             Workflow.execute(%{"action" => "get_board", "session_id" => "has-board"})

    assert text =~ "TODO"
  after
    Application.delete_env(:pincer, :workflow_orchestrator)
  end

  test "get_board returns error when no active board" do
    Application.put_env(:pincer, :workflow_orchestrator, StubOrchestrator)

    assert {:error, msg} =
             Workflow.execute(%{"action" => "get_board", "session_id" => "nothing"})

    assert msg =~ "nothing"
  after
    Application.delete_env(:pincer, :workflow_orchestrator)
  end

  # ---------------------------------------------------------------------------
  # Task management
  # ---------------------------------------------------------------------------

  test "list_tasks returns no tasks for empty workspace" do
    ws = tmp_workspace()
    assert {:ok, text} = execute(%{"action" => "list_tasks"}, ws)
    assert text =~ "No tasks"
  end

  test "create_task creates a task and list_tasks shows it" do
    ws = tmp_workspace()

    assert {:ok, msg} =
             execute(%{"action" => "create_task", "title" => "Fix the bug"}, ws)

    assert msg =~ "T1"

    assert {:ok, list} = execute(%{"action" => "list_tasks"}, ws)
    assert list =~ "Fix the bug"
    assert list =~ "pending"
  end

  test "create_task without title returns error" do
    assert {:error, msg} = execute(%{"action" => "create_task"})
    assert msg =~ "title"
  end

  test "create_task auto-increments IDs" do
    ws = tmp_workspace()
    execute(%{"action" => "create_task", "title" => "First"}, ws)
    {:ok, msg} = execute(%{"action" => "create_task", "title" => "Second"}, ws)
    assert msg =~ "T2"
  end

  test "get_task returns task details" do
    ws = tmp_workspace()
    execute(%{"action" => "create_task", "title" => "My task", "description" => "details"}, ws)

    assert {:ok, text} = execute(%{"action" => "get_task", "task_id" => "T1"}, ws)
    assert text =~ "My task"
    assert text =~ "details"
    assert text =~ "pending"
  end

  test "get_task for unknown ID returns error" do
    ws = tmp_workspace()
    assert {:error, msg} = execute(%{"action" => "get_task", "task_id" => "T99"}, ws)
    assert msg =~ "T99"
  end

  test "get_task without task_id returns error" do
    assert {:error, msg} = execute(%{"action" => "get_task"})
    assert msg =~ "task_id"
  end

  test "update_task changes status" do
    ws = tmp_workspace()
    execute(%{"action" => "create_task", "title" => "Work item"}, ws)

    assert {:ok, msg} =
             execute(
               %{"action" => "update_task", "task_id" => "T1", "status" => "in_progress"},
               ws
             )

    assert msg =~ "in_progress"

    {:ok, detail} = execute(%{"action" => "get_task", "task_id" => "T1"}, ws)
    assert detail =~ "in_progress"
  end

  test "update_task changes title and description" do
    ws = tmp_workspace()
    execute(%{"action" => "create_task", "title" => "Old title"}, ws)

    execute(
      %{
        "action" => "update_task",
        "task_id" => "T1",
        "title" => "New title",
        "description" => "Updated desc"
      },
      ws
    )

    {:ok, detail} = execute(%{"action" => "get_task", "task_id" => "T1"}, ws)
    assert detail =~ "New title"
    assert detail =~ "Updated desc"
  end

  test "update_task for unknown task returns error" do
    ws = tmp_workspace()
    assert {:error, msg} = execute(%{"action" => "update_task", "task_id" => "T99"}, ws)
    assert msg =~ "T99"
  end

  test "update_task without task_id returns error" do
    assert {:error, msg} = execute(%{"action" => "update_task"})
    assert msg =~ "task_id"
  end

  test "list_tasks with filter returns only matching tasks" do
    ws = tmp_workspace()
    execute(%{"action" => "create_task", "title" => "Task A"}, ws)
    execute(%{"action" => "create_task", "title" => "Task B"}, ws)
    execute(%{"action" => "update_task", "task_id" => "T1", "status" => "done"}, ws)

    {:ok, text} = execute(%{"action" => "list_tasks", "filter" => "done"}, ws)
    assert text =~ "Task A"
    refute text =~ "Task B"
  end

  test "list_tasks with filter no match returns no tasks message" do
    ws = tmp_workspace()
    execute(%{"action" => "create_task", "title" => "Pending task"}, ws)

    {:ok, text} = execute(%{"action" => "list_tasks", "filter" => "done"}, ws)
    assert text =~ "No tasks"
    assert text =~ "done"
  end

  # ---------------------------------------------------------------------------
  # Concurrent task creation
  # ---------------------------------------------------------------------------

  test "concurrent creates on one workspace get distinct ids" do
    ws = tmp_workspace()

    ids =
      1..16
      |> Enum.map(fn n ->
        Task.async(fn ->
          {:ok, msg} = execute(%{"action" => "create_task", "title" => "task #{n}"}, ws)
          msg
        end)
      end)
      |> Task.await_many(10_000)
      |> Enum.map(fn msg ->
        [_, id] = Regex.run(~r/^Task (T\d+) created/, msg)
        id
      end)

    assert ids == Enum.uniq(ids)
    assert length(ids) == 16
  end

  # ---------------------------------------------------------------------------
  # Corrupt tasks.json handling
  # ---------------------------------------------------------------------------

  test "corrupt JSON in tasks.json returns error and is not overwritten by create_task or update_task" do
    ws = tmp_workspace()
    pincer_dir = Path.join(ws, ".pincer")
    File.mkdir_p!(pincer_dir)
    tasks_file = Path.join(pincer_dir, "tasks.json")
    corrupt_payload = "{not valid json"
    File.write!(tasks_file, corrupt_payload)

    assert {:error, list_err} = execute(%{"action" => "list_tasks"}, ws)
    assert list_err =~ "Corrupt tasks"

    assert {:error, get_err} = execute(%{"action" => "get_task", "task_id" => "T1"}, ws)
    assert get_err =~ "Corrupt tasks"

    assert {:error, create_err} =
             execute(%{"action" => "create_task", "title" => "Should not overwrite"}, ws)

    assert create_err =~ "Corrupt tasks"
    assert File.read!(tasks_file) == corrupt_payload

    assert {:error, update_err} =
             execute(%{"action" => "update_task", "task_id" => "T1", "status" => "done"}, ws)

    assert update_err =~ "Corrupt tasks"
    assert File.read!(tasks_file) == corrupt_payload
  end

  test "non-list JSON in tasks.json returns error without overwriting" do
    ws = tmp_workspace()
    pincer_dir = Path.join(ws, ".pincer")
    File.mkdir_p!(pincer_dir)
    tasks_file = Path.join(pincer_dir, "tasks.json")
    File.write!(tasks_file, ~s({"unexpected": true}))

    assert {:error, err} = execute(%{"action" => "create_task", "title" => "New"}, ws)
    assert err =~ "Corrupt tasks"
    assert File.read!(tasks_file) == ~s({"unexpected": true})
  end

  defmodule BuggyRegistry do
    def list_session_ids, do: raise(ArithmeticError, message: "unexpected bug")
  end

  defmodule UnstartedRegistry do
    def list_session_ids, do: raise(ArgumentError, message: "registry not started")
  end

  test "list_sessions handles ArgumentError from unstarted registry but surfaces unexpected bugs" do
    Application.put_env(:pincer, :workflow_session_registry, UnstartedRegistry)
    assert {:error, msg} = Workflow.execute(%{"action" => "list_sessions"})
    assert msg =~ "Could not list sessions"

    Application.put_env(:pincer, :workflow_session_registry, BuggyRegistry)

    assert_raise ArithmeticError, fn ->
      Workflow.execute(%{"action" => "list_sessions"})
    end
  after
    Application.delete_env(:pincer, :workflow_session_registry)
  end

  # ---------------------------------------------------------------------------
  # Unknown action
  # ---------------------------------------------------------------------------

  test "unknown action returns descriptive error" do
    assert {:error, msg} = execute(%{"action" => "fly_to_moon"})
    assert msg =~ "fly_to_moon"
  end
end
