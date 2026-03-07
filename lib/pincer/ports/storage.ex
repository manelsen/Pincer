defmodule Pincer.Ports.Storage do
  @moduledoc "Port for persistent storage."
  
  @callback get_messages(String.t()) :: [map()]
  @callback save_message(String.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  @callback delete_messages(String.t()) :: :ok | {:error, term()}
  @callback ingest_bug_fix(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback query_history() :: [map()]
  @callback save_learning(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  @callback save_tool_error(String.t(), map(), String.t()) :: {:ok, term()} | {:error, term()}
  @callback list_recent_learnings(integer()) :: [map()]
  @callback index_document(String.t(), String.t(), [float()]) :: :ok | {:error, term()}
  @callback search_similar(String.t(), [float()], integer()) :: {:ok, [map()]} | {:error, term()}

  # --- Dispatcher ---

  defp adapter do
    # Default to Pincer.Storage (the facade/adapter) if not configured
    Application.get_env(:pincer, :storage_adapter, Pincer.Storage)
  end

  def get_messages(session_id), do: adapter().get_messages(session_id)
  def save_message(session_id, role, content), do: adapter().save_message(session_id, role, content)
  def delete_messages(session_id), do: adapter().delete_messages(session_id)
  def ingest_bug_fix(bug, fix, file), do: adapter().ingest_bug_fix(bug, fix, file)
  def query_history, do: adapter().query_history()
  def save_learning(cat, sum), do: adapter().save_learning(cat, sum)
  def save_tool_error(tool, args, err), do: adapter().save_tool_error(tool, args, err)
  def list_recent_learnings(limit), do: adapter().list_recent_learnings(limit)
  def index_document(path, content, vector), do: adapter().index_document(path, content, vector)
  def search_similar(type, vector, limit), do: adapter().search_similar(type, vector, limit)
end
