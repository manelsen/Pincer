defmodule Pincer.Storage do
  @moduledoc """
  Unified interface for storage operations using the configured adapter.

  This module provides a facade over the storage layer, delegating all
  operations to a configured adapter via the Adapter Pattern. This allows
  the application to switch storage backends (SQLite, PostgreSQL, Graph, etc.)
  without changing business logic.

  ## Architecture

      ┌─────────────────┐
      │  Pincer.Storage │  ← Facade (this module)
      └────────┬────────┘
               │ delegates to
               ▼
      ┌─────────────────┐
      │ Storage.Adapter │  ← Implementation (SQLite, Graph, etc.)
      └─────────────────┘

  ## Configuration

  Set the adapter in your `config/config.exs`:

      config :pincer,
        storage_adapter: Pincer.Storage.Adapters.SQLite

  If not configured, defaults to `Pincer.Storage.Adapters.SQLite`.

  ## Adapter Pattern

  To implement a new storage adapter:

  1. Create a module that implements `Pincer.Storage.Port` behaviour
  2. Implement all required callbacks (`get_messages/1`, `save_message/3`)
  3. Configure your adapter in application config

  ## Examples

      # Save a message to the current session
      Pincer.Storage.save_message("session-123", "user", "Hello, world!")
      #=> {:ok, %Pincer.Storage.Message{...}}

      # Retrieve all messages for a session
      Pincer.Storage.get_messages("session-123")
      #=> [%{role: "user", content: "Hello, world!"}]

  """

  @type session_id :: String.t()
  @type role :: String.t() | atom()
  @type content :: String.t()

  @spec adapter() :: module()
  defp adapter do
    Application.get_env(:pincer, :storage_adapter, Pincer.Storage.Adapters.SQLite)
  end

  @doc """
  Retrieves all messages for a given session, ordered chronologically.

  Returns a list of maps with `:role` and `:content` keys.

  ## Parameters

    - `session_id` - Unique identifier for the conversation session

  ## Examples

      iex> Pincer.Storage.get_messages("session-abc")
      [%{role: "user", content: "What is Elixir?"},
       %{role: "assistant", content: "Elixir is a functional language..."}]

      iex> Pincer.Storage.get_messages("nonexistent")
      []

  """
  @spec get_messages(session_id()) :: [%{role: String.t(), content: String.t()}]
  def get_messages(session_id), do: adapter().get_messages(session_id)

  @doc """
  Persists a message to storage.

  The role is automatically converted to string if an atom is provided,
  ensuring consistent storage format.

  ## Parameters

    - `session_id` - Unique identifier for the conversation session
    - `role` - Message origin (`:user`, `:assistant`, or string)
    - `content` - The message text content

  ## Returns

    - `{:ok, message}` - Successfully saved message struct
    - `{:error, changeset}` - Validation or database error

  ## Examples

      iex> Pincer.Storage.save_message("session-123", :user, "Hello!")
      {:ok, %Pincer.Storage.Message{session_id: "session-123", role: "user", ...}}

      iex> Pincer.Storage.save_message("session-123", "assistant", "Hi there!")
      {:ok, %Pincer.Storage.Message{...}}

  """
  @spec save_message(session_id(), role(), content()) ::
          {:ok, Pincer.Storage.Message.t()} | {:error, Ecto.Changeset.t()}
  def save_message(session_id, role, content) do
    adapter().save_message(session_id, to_string(role), content)
  end

  @doc """
  Searches for messages semantically similar to the query.

  Uses vector embeddings to find contextually relevant past messages.
  Currently returns an empty list in the Ultra-Light architecture
  (embedding generation disabled for MVP).

  ## Parameters

    - `query` - Text to search for similar messages
    - `limit` - Maximum number of results (default: 5)

  ## Examples

      iex> Pincer.Storage.search_similar_messages("bug fix", 3)
      []

  """
  @spec search_similar_messages(query :: String.t(), limit :: pos_integer()) :: [map()]
  def search_similar_messages(query, limit \\ 5) do
    adapter().search_similar_messages(query, limit)
  end
end
