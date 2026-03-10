defmodule Pincer.Storage.Message do
  @moduledoc """
  Ecto schema for message persistence.

  Represents a single message in a conversation session, stored in the
  `messages` table. Each message tracks:

  - Which session it belongs to (`session_id`)
  - Who sent it (`role`: "user", "assistant", "system")
  - The content (`content`)
  - Optional vector embedding for semantic search (`embedding`)

  ## Schema

  | Field | Type | Description |
  |-------|------|-------------|
  | `session_id` | `string` | Conversation session identifier |
  | `role` | `string` | Message origin (user/assistant/system) |
  | `content` | `string` | Message text content |
  | `embedding` | `vector` | Vector embedding for semantic search (optional) |
  | `inserted_at` | `utc_datetime` | Creation timestamp |
  | `updated_at` | `utc_datetime` | Last update timestamp |

  ## Examples

      # Creating a new message
      %Pincer.Storage.Message{}
      |> Pincer.Storage.Message.changeset(%{
        session_id: "sess-123",
        role: "user",
        content: "Hello!"
      })
      #=> #Ecto.Changeset<...>

  ## Database Migration

  Ensure your database has the `messages` table:

      create table(:messages) do
        add :session_id, :string, null: false
        add :role, :string, null: false
        add :content, :string, null: false
        add :embedding, :vector

        timestamps()
      end

      create index(:messages, [:session_id])

  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          session_id: String.t(),
          role: String.t(),
          content: String.t(),
          embedding: Pgvector.Ecto.Vector.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "messages" do
    field(:session_id, :string)
    field(:role, :string)
    field(:content, :string)
    field(:embedding, Pgvector.Ecto.Vector)

    timestamps()
  end

  @doc """
  Creates a changeset for validating and casting message attributes.

  ## Required Fields

    - `session_id` - Must be present
    - `role` - Must be present
    - `content` - Must be present

  ## Optional Fields

    - `embedding` - Vector embedding data

  ## Examples

      iex> Pincer.Storage.Message.changeset(%Pincer.Storage.Message{}, %{
      ...>   session_id: "sess-1",
      ...>   role: "user",
      ...>   content: "Hello"
      ...> })
      #Ecto.Changeset<valid: true, ...>

      iex> Pincer.Storage.Message.changeset(%Pincer.Storage.Message{}, %{role: "user"})
      #Ecto.Changeset<valid: false, errors: [session_id: "can't be blank", ...]>

  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:session_id, :role, :content, :embedding])
    |> validate_required([:session_id, :role, :content])
  end
end
