defmodule Pincer.Storage.Adapters.SQLite do
  @moduledoc """
  SQLite-based storage adapter for message persistence.

  This is the default storage adapter for Pincer, providing reliable
  message storage using SQLite via Ecto. It's ideal for:

  - Development and testing
  - Single-machine deployments
  - MVP and prototype applications

  ## Features

  - Full message persistence with timestamps
  - Session-based message grouping
  - Chronological message retrieval
  - Prepared for vector embedding storage (Ultra-Light: disabled)

  ## Limitations

  Semantic search (`search_similar_messages/2`) is disabled in the
  Ultra-Light architecture and returns an empty list. Enable embeddings
  in a full deployment for semantic search capabilities.

  ## Configuration

  This adapter is used by default. To explicitly configure:

      config :pincer,
        storage_adapter: Pincer.Storage.Adapters.SQLite

  ## Examples

      # Direct adapter usage (typically via Pincer.Storage facade)
      alias Pincer.Storage.Adapters.SQLite

      SQLite.save_message("session-1", "user", "Hello")
      #=> {:ok, %Pincer.Storage.Message{...}}

      SQLite.get_messages("session-1")
      #=> [%{role: "user", content: "Hello"}]

  """

  @behaviour Pincer.Storage.Port

  alias Pincer.Repo
  alias Pincer.Storage.Message
  import Ecto.Query
  require Logger

  @impl true
  @doc """
  Retrieves all messages for a session in chronological order.

  ## Parameters

    - `session_id` - The session identifier to query

  ## Returns

  A list of maps with `:role` and `:content` keys, ordered by insertion time.

  ## Examples

      iex> Pincer.Storage.Adapters.SQLite.get_messages("sess-123")
      [%{role: "user", content: "First message"},
       %{role: "assistant", content: "Response"}]

      iex> Pincer.Storage.Adapters.SQLite.get_messages("empty-session")
      []

  """
  @spec get_messages(String.t()) :: [%{role: String.t(), content: String.t()}]
  def get_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
    |> Enum.map(fn m -> %{role: m.role, content: m.content} end)
  end

  @impl true
  @doc """
  Persists a message to the SQLite database.

  ## Parameters

    - `session_id` - The session this message belongs to
    - `role` - Message origin ("user", "assistant", "system")
    - `content` - The message text

  ## Returns

    - `{:ok, message}` - Successfully saved message struct
    - `{:error, changeset}` - Validation error with details

  ## Examples

      iex> Pincer.Storage.Adapters.SQLite.save_message("s1", "user", "Hi")
      {:ok, %Pincer.Storage.Message{session_id: "s1", role: "user", content: "Hi", ...}}

      iex> Pincer.Storage.Adapters.SQLite.save_message("s1", "", "")
      {:error, #Ecto.Changeset<errors: [...]>}

  """
  @spec save_message(String.t(), String.t(), String.t()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def save_message(session_id, role, content) do
    case %Message{}
         |> Message.changeset(%{session_id: session_id, role: role, content: content})
         |> Repo.insert() do
      {:ok, message} ->
        {:ok, message}

      error ->
        error
    end
  end

  @doc """
  Searches for semantically similar messages using vector embeddings.

  **Note**: This feature is disabled in the Ultra-Light architecture.
  Always returns an empty list. Enable embeddings for semantic search.

  ## Parameters

    - `_query_text` - The search query (unused in Ultra-Light mode)
    - `_limit` - Maximum results to return (unused in Ultra-Light mode)

  ## Returns

  Always returns `[]` in Ultra-Light mode.

  ## Examples

      iex> Pincer.Storage.Adapters.SQLite.search_similar_messages("bug fix", 5)
      []

  """
  @spec search_similar_messages(String.t(), pos_integer()) :: []
  def search_similar_messages(_query_text, _limit \\ 5) do
    []
  end
end
