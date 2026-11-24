defmodule Pincer.Core.Project.Store do
  @moduledoc """
  Durable storage facade for project state.

  Project snapshots are stored as opaque terms in the storage adapter. This
  module owns the status vocabulary and normalizes atom/string keys so callers
  can persist either the independent `Project.Server` state or the
  session-scoped `ProjectOrchestrator` state without sharing storage details.
  """

  @statuses %{
    planning: "planning",
    awaiting_approval: "awaiting_approval",
    running: "running",
    paused: "paused",
    error: "error",
    completed: "completed",
    stopped: "stopped"
  }

  @type status ::
          :planning | :awaiting_approval | :running | :paused | :error | :completed | :stopped

  @type project :: %{
          id: String.t(),
          session_id: String.t(),
          kind: String.t(),
          status: status(),
          payload: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Persists or updates a project snapshot."
  @spec save(map()) :: :ok | {:error, term()}
  def save(project) when is_map(project) do
    with {:ok, id} <- required_string(project, :id),
         {:ok, session_id} <- required_string(project, :session_id),
         {:ok, kind} <- required_string(project, :kind),
         {:ok, status} <- project_status_string(project),
         {:ok, payload} <- payload(project) do
      Pincer.Ports.Storage.save_project(%{
        id: id,
        session_id: session_id,
        kind: kind,
        status: status,
        payload: payload
      })
    end
  end

  @doc "Loads a project snapshot by id."
  @spec load(String.t()) :: {:ok, project()} | {:error, term()}
  def load(id) when is_binary(id), do: Pincer.Ports.Storage.load_project(id)

  @doc """
  Lists project snapshots. Supports `:session_id`, `:kind`, `:status`, and
  `:limit` filters.
  """
  @spec list(keyword()) :: {:ok, [project()]} | {:error, term()}
  def list(opts \\ []) when is_list(opts), do: Pincer.Ports.Storage.list_projects(opts)

  @doc "Deletes a project snapshot."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(id) when is_binary(id), do: Pincer.Ports.Storage.delete_project(id)

  @doc "Deletes all snapshots of a kind. Intended for tests and reset flows."
  @spec delete_kind(String.t()) :: :ok | {:error, term()}
  def delete_kind(kind) when is_binary(kind),
    do: Pincer.Ports.Storage.delete_projects_by_kind(kind)

  @doc "Returns the canonical external status string."
  @spec status_string(status()) :: String.t()
  def status_string(status), do: Map.fetch!(@statuses, status)

  @doc "Converts a status string into its atom form, or `:unknown`."
  @spec status_atom(String.t()) :: status() | :unknown
  def status_atom("planning"), do: :planning
  def status_atom("awaiting_approval"), do: :awaiting_approval
  def status_atom("running"), do: :running
  def status_atom("paused"), do: :paused
  def status_atom("error"), do: :error
  def status_atom("completed"), do: :completed
  def status_atom("stopped"), do: :stopped
  def status_atom(_), do: :unknown

  defp required_string(map, key) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key))) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_project, key}}
    end
  end

  defp project_status_string(project) do
    status = Map.get(project, :status, Map.get(project, "status", :planning))

    case Map.fetch(@statuses, status) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_project_status, status}}
    end
  end

  defp payload(project) do
    case Map.get(project, :payload, Map.get(project, "payload", %{})) do
      payload when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_project_payload}
    end
  end
end
