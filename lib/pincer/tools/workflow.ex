defmodule Pincer.Adapters.Tools.Workflow do
  @moduledoc """
  Runtime inspection and task management tool for Pincer agents.

  Exposes the Pincer runtime state (active sessions, agents, project boards) and
  provides a lightweight task tracker backed by a JSON file in the workspace.

  ## Actions

  ### Runtime inspection
  | Action           | Description                                            |
  |------------------|--------------------------------------------------------|
  | `list_sessions`  | List active session IDs                                |
  | `get_session`    | Get status of a specific session                       |
  | `list_agents`    | List known agent IDs in the workspace directory        |
  | `list_projects`  | List projects for the current session                  |
  | `get_board`      | Show the kanban project board for a session            |

  ### Task management (workspace-scoped)
  | Action        | Description                                               |
  |---------------|-----------------------------------------------------------|
  | `list_tasks`  | List tasks from the session task file                     |
  | `create_task` | Create a new task                                         |
  | `get_task`    | Get details of a task by ID                               |
  | `update_task` | Update task status or fields                              |

  Tasks are persisted as JSON in `<workspace>/.pincer/tasks.json`. Each task has:
  `id`, `title`, `description`, `status` (`pending`/`in_progress`/`done`/`cancelled`),
  `created_at`, `updated_at`.
  """

  @behaviour Pincer.Ports.Tool

  require Logger

  alias Pincer.Core.AgentRegistry
  alias Pincer.Core.ProjectOrchestrator
  alias Pincer.Core.Session.Server, as: SessionServer

  @task_statuses ["pending", "in_progress", "done", "cancelled"]

  # ---------------------------------------------------------------------------
  # spec/0
  # ---------------------------------------------------------------------------

  @impl true
  def spec do
    %{
      name: "workflow",
      description:
        "Inspects the Pincer runtime (active sessions, agents, projects, kanban board) and manages a lightweight task list scoped to the current workspace.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            description:
              "Action: 'list_sessions', 'get_session', 'list_agents', 'list_projects', 'get_board', 'list_tasks', 'create_task', 'get_task', 'update_task'",
            enum: [
              "list_sessions",
              "get_session",
              "list_agents",
              "list_projects",
              "get_board",
              "list_tasks",
              "create_task",
              "get_task",
              "update_task"
            ]
          },
          session_id: %{
            type: "string",
            description:
              "Target session ID. Defaults to the current session when omitted."
          },
          task_id: %{
            type: "string",
            description: "Task ID (required for 'get_task', 'update_task')"
          },
          title: %{
            type: "string",
            description: "Task title (required for 'create_task')"
          },
          description: %{
            type: "string",
            description: "Task description"
          },
          status: %{
            type: "string",
            description: "Task status for 'update_task': 'pending', 'in_progress', 'done', 'cancelled'",
            enum: @task_statuses
          },
          filter: %{
            type: "string",
            description: "Filter tasks by status for 'list_tasks' (e.g. 'pending')"
          }
        },
        required: ["action"]
      }
    }
  end

  # ---------------------------------------------------------------------------
  # execute/2
  # ---------------------------------------------------------------------------

  @impl true
  def execute(%{"action" => action} = args, context \\ %{}) do
    session_id =
      Map.get(args, "session_id") || Map.get(context, "session_id") || "default"

    workspace =
      Map.get(context, "workspace_path") ||
        Path.join("workspaces", session_id)

    deps = %{
      session_registry: Application.get_env(:pincer, :workflow_session_registry, __MODULE__.DefaultSessionRegistry),
      session_server: Application.get_env(:pincer, :workflow_session_server, SessionServer),
      orchestrator: Application.get_env(:pincer, :workflow_orchestrator, ProjectOrchestrator)
    }

    run_action(action, args, session_id, workspace, deps)
  end

  # ---------------------------------------------------------------------------
  # Runtime inspection actions
  # ---------------------------------------------------------------------------

  defp run_action("list_sessions", _args, _sid, _ws, deps) do
    sessions =
      deps.session_registry.list_session_ids()
      |> Enum.sort()

    if sessions == [] do
      {:ok, "No active sessions."}
    else
      {:ok, "Active sessions (#{length(sessions)}):\n" <> Enum.map_join(sessions, "\n", &"- #{&1}")}
    end
  rescue
    e -> {:error, "Could not list sessions: #{Exception.message(e)}"}
  end

  defp run_action("get_session", args, current_sid, _ws, deps) do
    target = Map.get(args, "session_id", current_sid)

    case deps.session_server.get_status(target) do
      {:ok, state} ->
        lines = [
          "Session: #{state.session_id}",
          "Status: #{state.status}",
          "Provider: #{state[:provider] || "default"}",
          "History length: #{length(state.history || [])}",
          "Workspace: #{state[:workspace_path] || "n/a"}"
        ]

        {:ok, Enum.join(lines, "\n")}

      {:error, reason} ->
        {:error, "Session '#{target}' not found: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Could not get session: #{Exception.message(e)}"}
  end

  defp run_action("list_agents", _args, _sid, _ws, _deps) do
    workspaces_dir = "workspaces"

    if File.dir?(workspaces_dir) do
      agents =
        File.ls!(workspaces_dir)
        |> Enum.filter(fn name ->
          File.dir?(Path.join(workspaces_dir, name))
        end)
        |> Enum.sort()

      if agents == [] do
        {:ok, "No agent workspaces found."}
      else
        registered =
          Enum.map(agents, fn id ->
            mark = if AgentRegistry.exists?(id), do: " [active]", else: ""
            "- #{id}#{mark}"
          end)

        {:ok, "Agent workspaces (#{length(agents)}):\n" <> Enum.join(registered, "\n")}
      end
    else
      {:ok, "No workspaces directory found."}
    end
  rescue
    e -> {:error, "Could not list agents: #{Exception.message(e)}"}
  end

  defp run_action("list_projects", args, current_sid, _ws, deps) do
    target = Map.get(args, "session_id", current_sid)
    projects = deps.orchestrator.list_projects(target)

    if projects == [] do
      {:ok, "No active projects for session '#{target}'."}
    else
      lines =
        Enum.map(projects, fn {name, info} ->
          phase = Map.get(info, :phase, "unknown")
          "- **#{name}** (phase: #{phase})"
        end)

      {:ok, "Projects for '#{target}' (#{length(projects)}):\n" <> Enum.join(lines, "\n")}
    end
  rescue
    e -> {:error, "Could not list projects: #{Exception.message(e)}"}
  end

  defp run_action("get_board", args, current_sid, _ws, deps) do
    target = Map.get(args, "session_id", current_sid)

    case deps.orchestrator.board(target) do
      {:ok, board_text} -> {:ok, board_text}
      :not_found -> {:error, "No active project board for session '#{target}'."}
    end
  rescue
    e -> {:error, "Could not get board: #{Exception.message(e)}"}
  end

  # ---------------------------------------------------------------------------
  # Task management actions
  # ---------------------------------------------------------------------------

  defp run_action("list_tasks", args, _sid, workspace, _deps) do
    filter = Map.get(args, "filter")
    tasks = load_tasks(workspace)

    filtered =
      if filter do
        Enum.filter(tasks, &(&1["status"] == filter))
      else
        tasks
      end

    if filtered == [] do
      {:ok, "No tasks" <> if(filter, do: " with status '#{filter}'", else: "") <> "."}
    else
      lines =
        Enum.map(filtered, fn t ->
          "[#{t["id"]}] **#{t["title"]}** — #{t["status"]}" <>
            if(t["description"] && t["description"] != "", do: "\n  #{t["description"]}", else: "")
        end)

      {:ok, "Tasks (#{length(filtered)}):\n\n" <> Enum.join(lines, "\n")}
    end
  end

  defp run_action("create_task", %{"title" => title} = args, _sid, workspace, _deps) do
    tasks = load_tasks(workspace)
    next_id = next_task_id(tasks)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    task = %{
      "id" => next_id,
      "title" => title,
      "description" => Map.get(args, "description", ""),
      "status" => "pending",
      "created_at" => now,
      "updated_at" => now
    }

    save_tasks(workspace, [task | tasks])
    {:ok, "Task #{next_id} created: #{title}"}
  end

  defp run_action("create_task", _args, _sid, _ws, _deps),
    do: {:error, "Missing required parameter: title"}

  defp run_action("get_task", %{"task_id" => task_id}, _sid, workspace, _deps) do
    tasks = load_tasks(workspace)

    case Enum.find(tasks, &(&1["id"] == task_id)) do
      nil ->
        {:error, "Task '#{task_id}' not found."}

      task ->
        lines = [
          "ID: #{task["id"]}",
          "Title: #{task["title"]}",
          "Status: #{task["status"]}",
          "Description: #{task["description"] || "(none)"}",
          "Created: #{task["created_at"]}",
          "Updated: #{task["updated_at"]}"
        ]

        {:ok, Enum.join(lines, "\n")}
    end
  end

  defp run_action("get_task", _args, _sid, _ws, _deps),
    do: {:error, "Missing required parameter: task_id"}

  defp run_action("update_task", %{"task_id" => task_id} = args, _sid, workspace, _deps) do
    tasks = load_tasks(workspace)

    case Enum.find_index(tasks, &(&1["id"] == task_id)) do
      nil ->
        {:error, "Task '#{task_id}' not found."}

      idx ->
        task = Enum.at(tasks, idx)
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        updated =
          task
          |> maybe_update("status", Map.get(args, "status"))
          |> maybe_update("title", Map.get(args, "title"))
          |> maybe_update("description", Map.get(args, "description"))
          |> Map.put("updated_at", now)

        new_tasks = List.replace_at(tasks, idx, updated)
        save_tasks(workspace, new_tasks)
        {:ok, "Task #{task_id} updated. Status: #{updated["status"]}"}
    end
  end

  defp run_action("update_task", _args, _sid, _ws, _deps),
    do: {:error, "Missing required parameter: task_id"}

  defp run_action(unknown, _args, _sid, _ws, _deps),
    do: {:error, "Unknown workflow action: #{unknown}"}

  # ---------------------------------------------------------------------------
  # Task file helpers
  # ---------------------------------------------------------------------------

  defp tasks_path(workspace) do
    Path.join([workspace, ".pincer", "tasks.json"])
  end

  defp load_tasks(workspace) do
    path = tasks_path(workspace)

    if File.exists?(path) do
      case Jason.decode(File.read!(path)) do
        {:ok, list} when is_list(list) -> list
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp save_tasks(workspace, tasks) do
    path = tasks_path(workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(tasks, pretty: true))
  end

  defp next_task_id([]), do: "T1"

  defp next_task_id(tasks) do
    max_n =
      tasks
      |> Enum.map(fn t ->
        case Integer.parse(String.trim_leading(t["id"] || "", "T")) do
          {n, ""} -> n
          _ -> 0
        end
      end)
      |> Enum.max(fn -> 0 end)

    "T#{max_n + 1}"
  end

  defp maybe_update(task, _key, nil), do: task
  defp maybe_update(task, key, value), do: Map.put(task, key, value)

  defmodule DefaultSessionRegistry do
    @moduledoc false
    def list_session_ids do
      Registry.select(Pincer.Core.Session.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    end
  end
end
