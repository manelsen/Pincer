defmodule Pincer.Storage.Graph.Edge do
  @moduledoc """
  Ecto schema for graph edges (relationships between nodes).

  Edges represent directed relationships between nodes in the knowledge
  graph. Each edge connects a source node (`from_id`) to a target node
  (`to_id`) with a typed relationship.

  ## Supported Edge Types

  | Type | From → To | Meaning |
  |------|-----------|---------|
  | `occurs_in` | bug → file | Bug was discovered in this file |
  | `solves` | fix → bug | This fix resolves the bug |

  ## Directionality

  Edges are **directed** - they have a source and target:

      from_id ──[type]──► to_id

  When querying, consider both directions:
  - Forward: "What file does this bug occur in?"
  - Reverse: "What bug does this fix solve?"

  ## Schema

  | Field | Type | Description |
  |-------|------|-------------|
  | `id` | `binary_id` | UUID primary key (auto-generated) |
  | `from_id` | `binary_id` | Source node UUID |
  | `to_id` | `binary_id` | Target node UUID |
  | `type` | `string` | Relationship type identifier |
  | `inserted_at` | `utc_datetime` | Creation timestamp |
  | `updated_at` | `utc_datetime` | Last update timestamp |

  ## Examples

      # Creating an edge linking a bug to a file
      %Pincer.Storage.Graph.Edge{}
      |> Pincer.Storage.Graph.Edge.changeset(%{
        from_id: bug_node_id,
        to_id: file_node_id,
        type: "occurs_in"
      })
      #=> #Ecto.Changeset<...>

  ## Database Migration

      create table(:edges, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :from_id, :binary_id, null: false
        add :to_id, :binary_id, null: false
        add :type, :string, null: false

        timestamps()
      end

      create index(:edges, [:from_id])
      create index(:edges, [:to_id])
      create index(:edges, [:type])

  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: binary() | nil,
          from_id: binary(),
          to_id: binary(),
          type: String.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "edges" do
    field(:from_id, :binary_id)
    field(:to_id, :binary_id)
    field(:type, :string)
    timestamps()
  end

  @doc """
  Creates a changeset for validating and casting edge attributes.

  ## Required Fields

    - `from_id` - Source node UUID
    - `to_id` - Target node UUID
    - `type` - Relationship type identifier

  ## Examples

      iex> Pincer.Storage.Graph.Edge.changeset(
      ...>   %Pincer.Storage.Graph.Edge{},
      ...>   %{from_id: "uuid-1", to_id: "uuid-2", type: "solves"}
      ...> )
      #Ecto.Changeset<valid: true, ...>

      iex> Pincer.Storage.Graph.Edge.changeset(
      ...>   %Pincer.Storage.Graph.Edge{},
      ...>   %{type: "occurs_in"}
      ...> )
      #Ecto.Changeset<valid: false, errors: [from_id: "can't be blank", ...]>

  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:from_id, :to_id, :type])
    |> validate_required([:from_id, :to_id, :type])
  end
end
