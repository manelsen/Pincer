defmodule Pincer.Storage.Graph.Node do
  @moduledoc """
  Ecto schema for graph nodes (entities in the knowledge graph).

  Nodes represent entities in the graph memory system. Each node has:

  - A `type` categorizing what kind of entity it represents
  - A `data` map containing type-specific properties
  - Auto-generated UUID primary key

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

  ## Database Migration

      create table(:nodes, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :type, :string, null: false
        add :data, :map, null: false

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
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "nodes" do
    field(:type, :string)
    field(:data, :map)
    timestamps()
  end

  @doc """
  Creates a changeset for validating and casting node attributes.

  ## Required Fields

    - `type` - Must be present, categorizes the node
    - `data` - Must be present, contains entity properties

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

  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(node, attrs) do
    node
    |> cast(attrs, [:type, :data])
    |> validate_required([:type, :data])
  end
end
