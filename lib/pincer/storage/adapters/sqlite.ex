defmodule Pincer.Storage.Adapters.SQLite do
  @moduledoc """
  Unified SQLite storage adapter for Pincer.
  Handles message persistence, knowledge graph relationships, and vector search.
  """

  @behaviour Pincer.Ports.Storage

  alias Pincer.Infra.Repo
  alias Pincer.Storage.Message
  alias Pincer.Storage.Graph.{Node, Edge}
  import Ecto.Query
  require Logger

  # --- Message Persistence ---

  @impl true
  def get_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
    |> Enum.map(fn m -> %{role: m.role, content: m.content} end)
  end

  @impl true
  def save_message(session_id, role, content) do
    case %Message{}
         |> Message.changeset(%{session_id: session_id, role: role, content: content})
         |> Repo.insert() do
      {:ok, message} -> {:ok, message}
      error -> error
    end
  end

  @impl true
  def delete_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> Repo.delete_all()

    :ok
  end

  # --- Graph & Knowledge Management ---

  @impl true
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

  @impl true
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

  @impl true
  def save_learning(category, summary) do
    data = %{
      "category" => category,
      "summary" => summary,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    create_node("learning", data)
  end

  @impl true
  def save_tool_error(tool, args, error) do
    data = %{
      "tool" => tool,
      "args" => args,
      "error" => error,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    create_node("tool_error", data)
  end

  @impl true
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

  # --- Vector Search (SQLite Stopgap) ---

  @impl true
  def index_document(path, content, vector) do
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

  @impl true
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

  # --- Private Helpers ---

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

  defp create_node(type, data) do
    %Node{}
    |> Node.changeset(%{type: type, data: data})
    |> Repo.insert()
  end

  defp create_edge(from_id, to_id, type) do
    %Edge{}
    |> Edge.changeset(%{from_id: from_id, to_id: to_id, type: type})
    |> Repo.insert()
  end

  defp find_connected_node(from_id, edge_type, target_type) do
    query =
      from(n in Node,
        join: e in Edge,
        on: e.to_id == n.id,
        where: e.from_id == ^from_id and e.type == ^edge_type and n.type == ^target_type
      )

    Repo.one(query)
  end

  defp find_connected_rev_node(to_id, edge_type, source_type) do
    query =
      from(n in Node,
        join: e in Edge,
        on: e.from_id == n.id,
        where: e.to_id == ^to_id and e.type == ^edge_type and n.type == ^source_type
      )

    Repo.one(query)
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
