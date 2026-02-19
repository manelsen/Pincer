defmodule Pincer.Storage do
  @moduledoc """
  Interface for storage operations using configured adapter.
  """
  defp adapter do
    # Default to SQLite for MVP if not specified
    Application.get_env(:pincer, :storage_adapter, Pincer.Storage.Adapters.SQLite)
  end

  def get_messages(session_id), do: adapter().get_messages(session_id)
  
  def save_message(session_id, role, content) do
    adapter().save_message(session_id, to_string(role), content)
  end

  def search_similar_messages(query, limit \\ 5) do
    adapter().search_similar_messages(query, limit)
  end
end
