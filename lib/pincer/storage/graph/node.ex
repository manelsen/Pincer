defmodule Pincer.Storage.Graph.Node do
  @moduledoc """
  Ecto schema for graph nodes (entities in the knowledge graph).

  Nodes represent entities in the graph memory system. Each node has:

  - A `type` categorizing what kind of entity it represents
  - A `data` map containing type-specific properties
  - Auto-generated UUID primary key
  - Memory-tracking fields for importance, access frequency, and recency

  ## Supported Node Types

  | Type | Data Schema | Purpose |
  |------|-------------|---------|
  | `file` | `%{"path" => string}` | Source code files |
  | `bug` | `%{"description" => string}` | Bug descriptions |
  | `fix` | `%{"summary" => string}` | Solution summaries |

  ## Schema

  | Field | Type | Description |
  |-------|------|-------------|
  | `id` | `binary_id` | UUID primary key (auto-generated) |
  | `type` | `string` | Entity type identifier |
  | `data` | `map` | JSON-serialized entity data |
  | `importance_score` | `float` | Relative importance in [0.0, 1.0] (default 0.5) |
  | `access_count` | `integer` | Number of times the node has been retrieved |
  | `last_accessed_at` | `utc_datetime` | Timestamp of most recent access |
  | `inserted_at` | `utc_datetime` | Creation timestamp |
  | `updated_at` | `utc_datetime` | Last update timestamp |

  ## Examples

      # Creating a bug node
      %Pincer.Storage.Graph.Node{}
      |> Pincer.Storage.Graph.Node.changeset(%{
        type: "bug",
        data: %{"description" => "Division by zero"}
      })
      #=> #Ecto.Changeset<...>

      # Creating a node with an explicit importance score
      %Pincer.Storage.Graph.Node{}
      |> Pincer.Storage.Graph.Node.changeset(%{
        type: "fix",
        data: %{"summary" => "Guard against nil"},
        importance_score: 0.9
      })
      #=> #Ecto.Changeset<valid: true, ...>

  ## Database Migration

      create table(:nodes, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :type, :string, null: false
        add :data, :map, null: false
        add :importance_score, :float, default: 0.5, null: false
        add :access_count, :integer, default: 0, null: false
        add :last_accessed_at, :utc_datetime, null: true

        timestamps()
      end

      create index(:nodes, [:type])
      create index(:nodes, [:inserted_at])

  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: binary() | nil,
          type: String.t(),
          data: map(),
          embedding: Pgvector.Ecto.Vector.t() | nil,
          importance_score: float(),
          access_count: non_neg_integer(),
          last_accessed_at: DateTime.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "nodes" do
    field(:type, :string)
    field(:data, :map)
    field(:embedding, Pgvector.Ecto.Vector)
    field(:importance_score, :float, default: 0.5)
    field(:access_count, :integer, default: 0)
    field(:last_accessed_at, :utc_datetime)
    timestamps()
  end

  @doc """
  Creates a changeset for validating and casting node attributes.

  ## Required Fields

    - `type` - Must be present, categorizes the node
    - `data` - Must be present, contains entity properties

  ## Optional Fields

    - `importance_score` - Float in `[0.0, 1.0]`; defaults to `0.5`
    - `access_count` - Non-negative integer; defaults to `0`
    - `last_accessed_at` - UTC datetime of last retrieval

  ## Examples

      iex> Pincer.Storage.Graph.Node.changeset(
      ...>   %Pincer.Storage.Graph.Node{},
      ...>   %{type: "file", data: %{"path" => "lib/app.ex"}}
      ...> )
      #Ecto.Changeset<valid: true, ...>

      iex> Pincer.Storage.Graph.Node.changeset(
      ...>   %Pincer.Storage.Graph.Node{},
      ...>   %{type: "bug"}
      ...> )
      #Ecto.Changeset<valid: false, errors: [data: "can't be blank"]>

      iex> Pincer.Storage.Graph.Node.changeset(
      ...>   %Pincer.Storage.Graph.Node{},
      ...>   %{type: "fix", data: %{"summary" => "ok"}, importance_score: 1.5}
      ...> )
      #Ecto.Changeset<valid: false, errors: [importance_score: {"must be at most %{number}", ...}]>

  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(node, attrs) do
    node
    |> cast(attrs, [:type, :data, :embedding, :importance_score, :access_count, :last_accessed_at])
    |> validate_required([:type, :data])
    |> validate_number(:importance_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:access_count, greater_than_or_equal_to: 0)
  end
end
