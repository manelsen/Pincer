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
  @callback index_memory(String.t(), String.t(), String.t(), [float()], keyword()) ::
              :ok | {:error, term()}
  @callback search_messages(String.t(), integer()) :: {:ok, [map()]} | {:error, term()}
  @callback search_documents(String.t(), integer()) :: {:ok, [map()]} | {:error, term()}
  @callback search_documents(String.t(), integer(), keyword()) ::
              {:ok, [map()]} | {:error, term()}
  @callback search_sessions(String.t(), integer()) :: {:ok, [map()]} | {:error, term()}
  @callback memory_report(integer()) :: {:ok, map()} | {:error, term()}
  @callback forget_memory(String.t()) :: :ok | {:error, term()}
  @callback search_similar(String.t(), [float()], integer()) :: {:ok, [map()]} | {:error, term()}

  # --- Dispatcher ---

  defp adapter do
    Application.get_env(:pincer, :storage_adapter, Pincer.Storage.Adapters.Postgres)
  end

  def get_messages(session_id), do: adapter().get_messages(session_id)

  def save_message(session_id, role, content),
    do: adapter().save_message(session_id, role, content)

  def delete_messages(session_id), do: adapter().delete_messages(session_id)
  def ingest_bug_fix(bug, fix, file), do: adapter().ingest_bug_fix(bug, fix, file)
  def query_history, do: adapter().query_history()
  def save_learning(cat, sum), do: adapter().save_learning(cat, sum)
  def save_tool_error(tool, args, err), do: adapter().save_tool_error(tool, args, err)
  def list_recent_learnings(limit), do: adapter().list_recent_learnings(limit)
  def index_document(path, content, vector), do: adapter().index_document(path, content, vector)

  def index_memory(path, content, memory_type, vector, opts \\ []),
    do: adapter().index_memory(path, content, memory_type, vector, opts)

  def search_messages(query, limit), do: adapter().search_messages(query, limit)
  def search_documents(query, limit), do: adapter().search_documents(query, limit)
  def search_documents(query, limit, opts), do: adapter().search_documents(query, limit, opts)
  def search_sessions(query, limit), do: adapter().search_sessions(query, limit)
  def memory_report(limit), do: adapter().memory_report(limit)
  def forget_memory(source), do: adapter().forget_memory(source)
  def search_similar(type, vector, limit), do: adapter().search_similar(type, vector, limit)
end
