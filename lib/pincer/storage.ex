defmodule Pincer.Storage do
  @moduledoc """
  Facade for storage operations, acting as a Dispatcher for Storage Adapters.
  Implements the Pincer.Ports.Storage behaviour.
  """
  use Boundary, deps: [Pincer.Core, Pincer.Infra, Pincer.Ports]
  @behaviour Pincer.Ports.Storage

  @spec adapter() :: module()
  defp adapter do
    Application.get_env(:pincer, :storage_adapter, Pincer.Storage.Adapters.SQLite)
  end

  @impl true
  def get_messages(session_id), do: adapter().get_messages(session_id)

  @impl true
  def save_message(session_id, role, content) do
    adapter().save_message(session_id, to_string(role), content)
  end

  @impl true
  def delete_messages(session_id), do: adapter().delete_messages(session_id)

  @impl true
  def ingest_bug_fix(bug, fix, file) do
    if function_exported?(adapter(), :ingest_bug_fix, 3) do
      adapter().ingest_bug_fix(bug, fix, file)
    else
      {:error, :not_supported}
    end
  end

  @impl true
  def query_history do
    if function_exported?(adapter(), :query_history, 0) do
      adapter().query_history()
    else
      []
    end
  end

  @impl true
  def save_learning(cat, sum), do: graph_adapter().save_learning(cat, sum)

  @impl true
  def save_tool_error(tool, args, err), do: graph_adapter().save_tool_error(tool, args, err)

  @impl true
  def list_recent_learnings(limit), do: graph_adapter().list_recent_learnings(limit)

  @impl true
  def index_document(path, content, vector), do: graph_adapter().index_document(path, content, vector)

  @impl true
  def search_similar(type, vector, limit), do: graph_adapter().search_similar(type, vector, limit)

  defp graph_adapter, do: Pincer.Storage.Adapters.Graph
end
