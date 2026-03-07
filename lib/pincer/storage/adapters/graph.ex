defmodule Pincer.Storage.Adapters.Graph do
  @moduledoc """
  Graph-based memory adapter for semantic knowledge storage.

  Unlike simple message persistence, this adapter stores information as
  a knowledge graph with typed nodes and edges. This enables:

  - Tracking relationships between bugs, fixes, and files
  - Querying historical context semantically
  - Building a learning memory of past solutions

  ## Graph Schema

  The graph consists of two entity types:

  ### Nodes (Entities)

  | Type | Data | Description |
  |------|------|-------------|
  | `file` | `%{"path" => string}` | Source code files |
  | `bug` | `%{"description" => string}` | Bug descriptions |
  | `fix` | `%{"summary" => string}` | Fix summaries |

  ### Edges (Relationships)

  | Type | From → To | Meaning |
  |------|-----------|---------|
  | `occurs_in` | bug → file | Bug was found in this file |
  | `solves` | fix → bug | Fix resolves this bug |

  ## Architecture

      ┌─────────┐  occurs_in   ┌──────┐
      │   Bug   │ ───────────► │ File │
      └────┬────┘              └──────┘
           ▲
           │ solves
           │
      ┌────┴────┐
      │   Fix   │
      └─────────┘

  ## Examples

      # Record a bug fix for future reference
      Pincer.Storage.Adapters.Graph.ingest_bug_fix(
        "Null pointer in user lookup",
        "Added nil check before accessing user.name",
        "lib/pincer/user.ex"
      )
      #=> {:ok, :ok}

      # Query recent bug history
      Pincer.Storage.Adapters.Graph.query_history()
      #=> [
      #   %{
      #     bug: "Null pointer in user lookup",
      #     file: "lib/pincer/user.ex",
      #     fix: "Added nil check before accessing user.name"
      #   }
      # ]

  ## Use Cases

  - **Learning Memory**: Remember past solutions to similar problems
  - **Context Enrichment**: Provide historical context to the AI
  - **Debugging Assistance**: Find related bugs and their fixes

  """

  import Ecto.Query
  alias Pincer.Infra.Repo
  alias Pincer.Storage.Graph.{Node, Edge}
  require Logger

  @type bug_description :: String.t()
  @type fix_summary :: String.t()
  @type file_path :: String.t()

  @doc """
  Records a bug fix in the knowledge graph.

  Creates or updates the following graph structure:
  1. Ensures the file node exists (idempotent by path)
  2. Creates a new bug node with the description
  3. Creates a new fix node with the summary
  4. Links: bug → file (occurs_in), fix → bug (solves)

  This operation is atomic (wrapped in a transaction).

  ## Parameters

    - `bug_desc` - Description of the bug encountered
    - `fix_summary` - Summary of how the bug was fixed
    - `file_path` - Path to the file where the bug occurred

  ## Returns

    - `{:ok, :ok}` - Successfully recorded
    - `{:error, reason}` - Transaction failed

  ## Examples

      iex> Pincer.Storage.Adapters.Graph.ingest_bug_fix(
      ...>   "Division by zero in calculate_total/1",
      ...>   "Guard clause for empty list",
      ...>   "lib/pincer/order.ex"
      ...> )
      {:ok, :ok}

  """
  @spec ingest_bug_fix(bug_description(), fix_summary(), file_path()) ::
          {:ok, :ok} | {:error, term()}
  def ingest_bug_fix(bug_desc, fix_summary, file_path) do
    Repo.transaction(fn ->
      file_node = ensure_node("file", %{"path" => file_path})
      {:ok, bug_node} = create_node("bug", %{"description" => bug_desc})
      {:ok, fix_node} = create_node("fix", %{"summary" => fix_summary})
      create_edge(bug_node.id, file_node.id, "occurs_in")
      create_edge(fix_node.id, bug_node.id, "solves")
      :ok
    end)
  end

  @doc """
  Queries the bug fix history.

  Returns the most recent 10 bugs with their associated files and fixes,
  ordered by recency.

  ## Returns

  A list of maps with:
  - `:bug` - Bug description
  - `:file` - File path where bug occurred (or "unknown")
  - `:fix` - Fix summary (or "no fix recorded")

  ## Examples

      iex> Pincer.Storage.Adapters.Graph.query_history()
      [
        %{
          bug: "Null pointer exception",
          file: "lib/pincer/user.ex",
          fix: "Added nil check"
        },
        %{
          bug: "Timeout on API call",
          file: "lib/pincer/api.ex",
          fix: "Increased timeout to 30s"
        }
      ]

  """
  @spec query_history() :: [%{bug: String.t(), file: String.t(), fix: String.t()}]
  def query_history do
    query =
      from(n in Node,
        where: n.type == "bug",
        order_by: [desc: n.inserted_at],
        limit: 10
      )

    Repo.all(query)
    |> Enum.map(fn bug ->
      file = find_connected_node(bug.id, "occurs_in", "file")
      fix = find_connected_rev_node(bug.id, "solves", "fix")

      %{
        bug: bug.data["description"],
        file: if(file, do: file.data["path"], else: "unknown"),
        fix: if(fix, do: fix.data["summary"], else: "no fix recorded")
      }
    end)
  end

  @spec ensure_node(String.t(), map()) :: Node.t()
  defp ensure_node(type, data) do
    case Repo.one(
           from(n in Node,
             where:
               n.type == ^type and fragment("json_extract(data, '$.path') = ?", ^data["path"])
           )
         ) do
      nil ->
        {:ok, node} = create_node(type, data)
        node

      node ->
        node
    end
  end

  @spec create_node(String.t(), map()) :: {:ok, Node.t()} | {:error, Ecto.Changeset.t()}
  defp create_node(type, data) do
    %Node{}
    |> Node.changeset(%{type: type, data: data})
    |> Repo.insert()
  end

  @spec create_edge(binary(), binary(), String.t()) ::
          {:ok, Edge.t()} | {:error, Ecto.Changeset.t()}
  defp create_edge(from_id, to_id, type) do
    %Edge{}
    |> Edge.changeset(%{from_id: from_id, to_id: to_id, type: type})
    |> Repo.insert()
  end

  @spec find_connected_node(binary(), String.t(), String.t()) :: Node.t() | nil
  defp find_connected_node(from_id, edge_type, target_type) do
    query =
      from(n in Node,
        join: e in Edge,
        on: e.to_id == n.id,
        where: e.from_id == ^from_id and e.type == ^edge_type and n.type == ^target_type
      )

    Repo.one(query)
  end

  @spec find_connected_rev_node(binary(), String.t(), String.t()) :: Node.t() | nil
  defp find_connected_rev_node(to_id, edge_type, source_type) do
    query =
      from(n in Node,
        join: e in Edge,
        on: e.from_id == n.id,
        where: e.to_id == ^to_id and e.type == ^edge_type and n.type == ^source_type
      )

    Repo.one(query)
  end

  @doc """
  Saves a new learning or user correction to the knowledge graph.
  """
  def save_learning(category, summary) do
    data = %{
      "category" => category,
      "summary" => summary,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    create_node("learning", data)
  end

  @doc """
  Saves a recurring tool error to the knowledge graph.
  """
  def save_tool_error(tool, args, error) do
    data = %{
      "tool" => tool,
      "args" => args,
      "error" => error,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    create_node("tool_error", data)
  end

  @doc """
  Lists the most recent learnings and tool errors.
  """
  def list_recent_learnings(limit \\ 3) do
    query =
      from(n in Node,
        where: n.type in ["tool_error", "learning"],
        order_by: [desc: n.inserted_at],
        limit: ^limit
      )

    Repo.all(query)
    |> Enum.map(fn n ->
      case n.type do
        "tool_error" -> %{type: :error, tool: n.data["tool"], error: n.data["error"]}
        "learning" -> %{type: :learning, category: n.data["category"], summary: n.data["summary"]}
      end
    end)
  end

  @doc """
  Indexes a document or chunk with its vector embedding in SQLite.
  """
  def index_document(path, content, vector) do
    # Convert float list to binary for BLOB storage
    embedding_bin = :erlang.term_to_binary(vector)

    case create_node("document", %{"path" => path, "content" => content}) do
      {:ok, node} ->
        node
        |> Node.changeset(%{embedding: embedding_bin})
        |> Repo.update()

        :ok

      error ->
        error
    end
  end

  @doc """
  Performs a brute-force cosine similarity search in SQLite.
  Suitable for "Stopgap" mode with small-to-medium datasets.
  """
  def search_similar(type, query_vector, limit \\ 5) do
    query = from(n in Node, where: n.type == ^type and not is_nil(n.embedding))

    Repo.all(query)
    |> Enum.map(fn node ->
      vector = :erlang.binary_to_term(node.embedding)
      score = cosine_similarity(query_vector, vector)
      %{node: node, score: score}
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
    |> then(fn results ->
      {:ok, Enum.map(results, &%{role: &1.node.type, content: &1.node.data["content"] || &1.node.data["path"]})}
    end)
  end

  defp cosine_similarity(v1, v2) do
    dot_product = Enum.zip(v1, v2) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
    mag1 = :math.sqrt(Enum.map(v1, fn x -> x * x end) |> Enum.sum())
    mag2 = :math.sqrt(Enum.map(v2, fn x -> x * x end) |> Enum.sum())

    if mag1 > 0 and mag2 > 0 do
      dot_product / (mag1 * mag2)
    else
      0.0
    end
  end
end
