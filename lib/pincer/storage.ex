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
end
