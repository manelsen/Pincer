defmodule Pincer.Storage.Port do
  @moduledoc """
  Behaviour definition for storage adapters.

  This module defines the contract that all storage adapters must implement.
  It follows the Ports and Adapters (Hexagonal) architecture pattern, where:

  - **Port** (this module) - Defines the interface/contract
  - **Adapter** - Concrete implementation (e.g., `Pincer.Storage.Adapters.SQLite`)

  ## Implementing an Adapter

  To create a new storage adapter:

      defmodule MyCustomAdapter do
        @behaviour Pincer.Storage.Port

        @impl true
        def get_messages(session_id) do
          # Your implementation
        end

        @impl true
        def save_message(session_id, role, content) do
          # Your implementation
        end
      end

  ## Required Callbacks

  | Callback | Purpose |
  |----------|---------|
  | `get_messages/1` | Retrieve all messages for a session |
  | `save_message/3` | Persist a new message |

  """

  @doc """
  Retrieves all messages for a given session.

  Implementations should return messages in chronological order
  (oldest first) as a list of maps with `:role` and `:content` keys.

  ## Parameters

    - `session_id` - The session identifier to query

  ## Returns

  A list of message maps, ordered chronologically.
  """
  @callback get_messages(session_id :: String.t()) :: [%{role: String.t(), content: String.t()}]

  @doc """
  Persists a message to the storage backend.

  ## Parameters

    - `session_id` - The session this message belongs to
    - `role` - The message origin ("user", "assistant", "system")
    - `content` - The message text

  ## Returns

    - `{:ok, message}` on success
    - `{:error, reason}` on failure
  """
  @callback save_message(session_id :: String.t(), role :: String.t(), content :: String.t()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Deletes all messages for a given session.
  """
  @callback delete_messages(session_id :: String.t()) :: :ok | {:error, term()}
end
