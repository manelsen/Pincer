defmodule Pincer.Core.ProjectOrchestrator do
  @moduledoc """
  Client interface for project orchestration.
  Now delegates project lifecycle to Pincer.Project.Supervisor and Pincer.Project.Server.
  """
  require Logger

  alias Pincer.Project.Supervisor, as: ProjectSupervisor
  alias Pincer.Project.Registry, as: ProjectRegistry

  @doc """
  Starts a new project GenServer.
  """
  def start(session_id, objective) do
    id = generate_id()
    case ProjectSupervisor.start_project(id: id, session_id: session_id, objective: objective) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all projects for a given session.
  """
  def list_projects(session_id) do
    # Filter projects from Registry or use a separate tracking table
    # For now, let's assume we can find them in the Registry
    Registry.select(Pincer.Project.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])
    |> Enum.filter(fn {_id, %{session_id: sid}} -> sid == session_id end)
  end

  defp generate_id do
    "p-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end
end
