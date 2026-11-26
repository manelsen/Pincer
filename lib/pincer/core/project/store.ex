defmodule Pincer.Core.Project.Store do
  @moduledoc """
  Durable and ETS-backed storage facade for project state.

  Project snapshots are stored as opaque terms in the storage adapter. This
  module owns the status vocabulary, normalizes atom/string keys, and
  consolidates the ETS cache + durable persistence used by `ProjectOrchestrator`
  alongside `Project.Server` snapshots.
  """

  require Logger

  alias Pincer.Core.Project.Plan
  alias Pincer.Core.Project.Wizard
  alias Pincer.Utils.ETSHelper

  @orchestrator_table Pincer.Core.ProjectOrchestrator
  @orchestrator_kind "orchestrator"

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

  @doc "Builds the deterministic durable project ID for a session."
  @spec build_project_id(String.t()) :: String.t()
  def build_project_id(session_id) when is_binary(session_id) do
    "project-" <> Plan.slugify(session_id, 24)
  end

  @doc "Ensures the ETS cache table for orchestrator session state exists."
  @spec ensure_orchestrator_table(atom()) :: :ok
  def ensure_orchestrator_table(table \\ @orchestrator_table) when is_atom(table) do
    _ =
      ETSHelper.ensure_named_table(table,
        options: [:set, :named_table, :public, read_concurrency: true]
      )

    :ok
  end

  @doc "Looks up an orchestrator session state from ETS or durable storage."
  @spec get_orchestrator_state(String.t(), atom()) :: map() | nil
  def get_orchestrator_state(session_id, table \\ @orchestrator_table)
      when is_binary(session_id) and is_atom(table) do
    ensure_orchestrator_table(table)

    case ets_lookup(table, session_id) do
      nil -> load_orchestrator_state(session_id, table)
      state -> state
    end
  end

  @doc "Writes an orchestrator session state to ETS and durable storage."
  @spec put_orchestrator_state(map(), atom()) :: map()
  def put_orchestrator_state(%{session_id: session_id} = state, table \\ @orchestrator_table)
      when is_binary(session_id) and is_atom(table) do
    ensure_orchestrator_table(table)
    clean_state = Map.delete(state, :phase)
    :ets.insert(table, {session_id, clean_state})
    persist_orchestrator_state(clean_state)
    clean_state
  rescue
    ArgumentError ->
      ensure_orchestrator_table(table)
      clean_state = Map.delete(state, :phase)
      :ets.insert(table, {session_id, clean_state})
      persist_orchestrator_state(clean_state)
      clean_state
  end

  @doc "Deletes a single session's orchestrator state from ETS and durable storage."
  @spec delete_orchestrator_state(String.t(), atom()) :: :ok
  def delete_orchestrator_state(session_id, table \\ @orchestrator_table)
      when is_binary(session_id) and is_atom(table) do
    ensure_orchestrator_table(table)
    :ets.delete(table, session_id)
    _ = delete(build_project_id(session_id))
    :ok
  end

  @doc "Clears all orchestrator states from ETS and durable storage."
  @spec reset_orchestrator_states(atom()) :: :ok
  def reset_orchestrator_states(table \\ @orchestrator_table) when is_atom(table) do
    ensure_orchestrator_table(table)
    :ets.delete_all_objects(table)
    _ = delete_kind(@orchestrator_kind)
    :ok
  end

  @doc "Maps an orchestrator state to a high-level summary status."
  @spec orchestrator_status(map()) ::
          :running | :completed | :pending_approval | :collecting | :unknown
  def orchestrator_status(%{items: items} = state) do
    case Wizard.phase(state) do
      :ready ->
        cond do
          Enum.any?(items, &(&1.status == :in_progress)) -> :running
          Enum.all?(items, &(&1.status == :done)) and items != [] -> :completed
          true -> :pending_approval
        end

      phase when phase in [:await_objective, :await_kind, :await_scope, :await_success] ->
        :collecting

      _ ->
        :unknown
    end
  end

  def orchestrator_status(_), do: :unknown

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

  defp ets_lookup(table, session_id) do
    case :ets.lookup(table, session_id) do
      [{^session_id, state}] -> state
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp load_orchestrator_state(session_id, table) do
    with {:ok, project} <- load(build_project_id(session_id)),
         @orchestrator_kind <- project.kind,
         ^session_id <- project.session_id,
         state when is_map(state) <- project.payload do
      normalized = normalize_loaded_state(state, session_id)
      :ets.insert(table, {session_id, normalized})
      normalized
    else
      _ -> nil
    end
  end

  defp normalize_loaded_state(state, session_id) do
    state
    |> Map.delete(:phase)
    |> Map.put(:session_id, session_id)
    |> sync_loaded_fsm_state()
    |> Map.update(:items, [], fn items ->
      Enum.map(items, fn
        %{status: :in_progress} = item -> %{item | status: :pending}
        item -> item
      end)
    end)
  end

  defp sync_loaded_fsm_state(%{fsm_state: fsm_state} = state) when is_map(fsm_state) do
    synced_fsm =
      fsm_state
      |> Map.put_new(:kind, Map.get(state, :kind))
      |> Map.put_new(:success_criteria, Map.get(state, :success_criteria))

    %{state | fsm_state: synced_fsm}
  end

  defp sync_loaded_fsm_state(state), do: state

  defp persist_orchestrator_state(%{session_id: session_id, project_id: project_id} = state) do
    project = %{
      id: project_id,
      session_id: session_id,
      kind: @orchestrator_kind,
      status: orchestrator_store_status(state),
      payload: state
    }

    case save(project) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[PROJECT] Orchestrator persistence failed: #{inspect(reason)}")
        :error
    end
  end

  defp orchestrator_store_status(state) do
    case Wizard.phase(state) do
      :ready ->
        items = Map.get(state, :items, [])

        cond do
          Enum.any?(items, &(&1.status == :in_progress)) -> :running
          Enum.all?(items, &(&1.status == :done)) and items != [] -> :completed
          true -> :awaiting_approval
        end

      _ ->
        :planning
    end
  end

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
