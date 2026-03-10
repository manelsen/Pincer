defmodule Pincer.Storage.Adapters.Postgres do
  @moduledoc """
  Unified PostgreSQL storage adapter for Pincer.

  The adapter keeps the public storage API stable while implementing:

  - message persistence in Postgres
  - JSONB-backed graph and memory metadata
  - PostgreSQL full-text search for transcripts and snippets
  - pgvector-backed semantic similarity for document memories
  """

  @behaviour Pincer.Ports.Storage

  alias Pincer.Core.MemoryTypes
  alias Pincer.Infra.Repo
  alias Pincer.Storage.Graph.{Edge, Node}
  alias Pincer.Storage.Message
  import Ecto.Query
  import Pgvector.Ecto.Query

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
    %Message{}
    |> Message.changeset(%{session_id: session_id, role: role, content: content})
    |> Repo.insert()
  end

  @impl true
  def delete_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> Repo.delete_all()

    :ok
  end

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

  @impl true
  def index_document(path, content, vector) do
    index_memory(path, content, "reference", vector, [])
  end

  @impl true
  def index_memory(path, content, memory_type, vector, opts \\ []) do
    metadata = build_memory_metadata(path, content, memory_type, opts)

    case find_node_by_path("document", path) do
      nil ->
        case create_node("document", metadata) do
          {:ok, node} ->
            node
            |> Node.changeset(%{embedding: vector})
            |> Repo.update()

            :ok

          error ->
            error
        end

      node ->
        node
        |> Node.changeset(%{data: metadata, embedding: vector})
        |> Repo.update()

        :ok
    end
  end

  @impl true
  def search_messages(query, limit \\ 5) do
    case search_messages_fts(query, limit) do
      {:ok, []} -> fallback_search_messages(query, limit)
      {:ok, _results} = ok -> ok
      {:error, _reason} -> fallback_search_messages(query, limit)
    end
  end

  @impl true
  def search_documents(query, limit \\ 5) do
    search_documents(query, limit, [])
  end

  @impl true
  def search_documents(query, limit, opts) do
    case search_documents_fts(query, limit, opts) do
      {:ok, []} -> fallback_search_documents(query, limit, opts)
      {:ok, _results} = ok -> ok
      {:error, _reason} -> fallback_search_documents(query, limit, opts)
    end
  end

  @impl true
  def search_sessions(query, limit \\ 5) do
    with {:ok, hits} <- search_messages(query, limit * 5) do
      grouped =
        hits
        |> Enum.group_by(fn hit -> extract_session_id(hit.source) end)
        |> Enum.map(fn {session_id, session_hits} ->
          ordered = Enum.sort_by(session_hits, &(-(Map.get(&1, :score) || 0.0)))

          %{
            session_id: session_id,
            hit_count: length(session_hits),
            preview: ordered |> hd() |> Map.get(:content),
            hits: Enum.take(ordered, limit)
          }
        end)
        |> Enum.sort_by(&{-&1.hit_count, &1.session_id})
        |> Enum.take(limit)

      {:ok, grouped}
    end
  end

  @impl true
  def forget_memory(source) do
    case find_node_by_path("document", source) do
      nil ->
        {:error, :not_found}

      node ->
        data =
          Map.put(node.data || %{}, "forgotten_at", DateTime.utc_now() |> DateTime.to_iso8601())

        node
        |> Node.changeset(%{data: data})
        |> Repo.update()

        :ok
    end
  end

  @impl true
  def search_similar(type, query_vector, limit \\ 5) do
    Node
    |> where([n], n.type == ^type and not is_nil(n.embedding))
    |> where([n], fragment("COALESCE(?->>'forgotten_at', '') = ''", n.data))
    |> select([n], {n, cosine_distance(n.embedding, ^query_vector)})
    |> order_by([n], asc: cosine_distance(n.embedding, ^query_vector), desc: n.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> then(fn rows ->
      {:ok,
       Enum.map(rows, fn {node, distance} ->
         score = rank_memory_score(node, 1.0 - distance)
         touch_memory_access(node)
         document_result(node, score)
       end)}
    end)
  end

  defp ensure_node(type, data) do
    case Repo.all(
           from(n in Node,
             where: n.type == ^type and fragment("?->>'path' = ?", n.data, ^data["path"])
           )
         ) do
      [] ->
        {:ok, node} = create_node(type, data)
        node

      [node | _] ->
        node
    end
  end

  defp find_node_by_path(type, path) do
    from(n in Node,
      where: n.type == ^type and fragment("?->>'path' = ?", n.data, ^path)
    )
    |> Repo.one()
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

  defp search_messages_fts(query, limit) do
    case normalize_tsquery(query) do
      "" ->
        {:ok, []}

      ts_query ->
        case Ecto.Adapters.SQL.query(
               Repo,
               """
               SELECT id,
                      session_id,
                      role,
                      content,
                      ts_rank_cd(
                        to_tsvector('simple', COALESCE(content, '')),
                        websearch_to_tsquery('simple', $1)
                      ) AS score
               FROM messages
               WHERE to_tsvector('simple', COALESCE(content, ''))
                     @@ websearch_to_tsquery('simple', $1)
               ORDER BY score DESC, inserted_at DESC
               LIMIT $2
               """,
               [ts_query, limit]
             ) do
          {:ok, %{rows: rows}} ->
            {:ok,
             Enum.map(rows, fn [id, session_id, role, content, score] ->
               %{
                 kind: :message,
                 role: role,
                 content: content,
                 source: "session:#{session_id}:message:#{id}",
                 citation: "session #{session_id} / #{role} / message ##{id}",
                 score: score
               }
             end)}

          error ->
            error
        end
    end
  end

  defp search_documents_fts(query, limit, opts) do
    case normalize_tsquery(query) do
      "" ->
        {:ok, []}

      ts_query ->
        {sql, params} = search_documents_sql(ts_query, limit, opts)

        case Ecto.Adapters.SQL.query(Repo, sql, params) do
          {:ok, %{rows: rows}} ->
            results =
              rows
              |> Enum.map(fn [node_id, score] ->
                node = Repo.get!(Node, node_id)
                ranked_score = rank_memory_score(node, score)
                touch_memory_access(node)
                {node, ranked_score}
              end)
              |> Enum.sort_by(
                fn {node, ranked_score} -> {ranked_score, node.inserted_at} end,
                :desc
              )
              |> Enum.map(fn {node, ranked_score} ->
                document_result(node, ranked_score)
              end)

            {:ok, results}

          error ->
            error
        end
    end
  end

  defp fallback_search_messages(query, limit) do
    tokens = search_tokens(query)

    results =
      Message
      |> order_by([m], desc: m.inserted_at)
      |> Repo.all()
      |> Enum.filter(fn message ->
        haystack = String.downcase(message.content || "")
        Enum.all?(tokens, &String.contains?(haystack, &1))
      end)
      |> Enum.take(limit)
      |> Enum.map(fn message ->
        %{
          kind: :message,
          role: message.role,
          content: message.content,
          source: "session:#{message.session_id}:message:#{message.id}",
          citation: "session #{message.session_id} / #{message.role} / message ##{message.id}"
        }
      end)

    {:ok, results}
  end

  defp fallback_search_documents(query, limit, opts) do
    tokens = search_tokens(query)

    results =
      from(n in Node, where: n.type == "document", order_by: [desc: n.inserted_at])
      |> Repo.all()
      |> Enum.filter(fn node ->
        haystack = String.downcase(node.data["content"] || "")

        Enum.all?(tokens, &String.contains?(haystack, &1)) and
          document_matches_opts?(node.data, opts) and
          (Keyword.get(opts, :include_forgotten, false) or not memory_forgotten?(node.data))
      end)
      |> Enum.map(fn node ->
        score =
          tokens
          |> Enum.count(&String.contains?(String.downcase(node.data["content"] || ""), &1))
          |> rank_memory_score(node)

        touch_memory_access(node)
        document_result(node, score)
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    {:ok, results}
  end

  defp normalize_tsquery(query), do: query |> to_string() |> String.trim()

  defp search_tokens(query) do
    query
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]_]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 2))
  end

  defp build_memory_metadata(path, content, memory_type, opts) do
    %{
      "path" => path,
      "content" => content,
      "memory_type" => MemoryTypes.normalize(memory_type),
      "importance" => normalize_importance(Keyword.get(opts, :importance, 5)),
      "access_count" => Keyword.get(opts, :access_count, 0),
      "last_accessed_at" => Keyword.get(opts, :last_accessed_at),
      "forgotten_at" => Keyword.get(opts, :forgotten_at),
      "session_id" => Keyword.get(opts, :session_id),
      "line_start" => Keyword.get(opts, :line_start),
      "line_end" => Keyword.get(opts, :line_end)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_importance(value) when is_integer(value), do: min(10, max(0, value))
  defp normalize_importance(_), do: 5

  defp document_matches_opts?(data, opts) do
    type_match? =
      case Keyword.get(opts, :memory_type) do
        nil -> true
        type -> data["memory_type"] == MemoryTypes.normalize(type)
      end

    session_match? =
      case Keyword.get(opts, :session_id) do
        nil -> true
        session_id -> data["session_id"] == session_id
      end

    type_match? and session_match?
  end

  defp memory_forgotten?(data),
    do: is_binary(data["forgotten_at"]) and String.trim(data["forgotten_at"]) != ""

  defp touch_memory_access(%Node{data: data} = node) do
    next_data =
      data
      |> Map.put("access_count", (data["access_count"] || 0) + 1)
      |> Map.put("last_accessed_at", DateTime.utc_now() |> DateTime.to_iso8601())

    node
    |> Node.changeset(%{data: next_data})
    |> Repo.update()

    :ok
  end

  defp document_result(node, score) do
    %{
      kind: :document,
      role: "document",
      content: node.data["content"],
      source: node.data["path"],
      citation: build_citation(node.data),
      score: score,
      memory_type: node.data["memory_type"] || "reference",
      importance: node.data["importance"] || 5,
      access_count: (node.data["access_count"] || 0) + 1,
      session_id: node.data["session_id"],
      forgotten?: memory_forgotten?(node.data)
    }
  end

  defp build_citation(data) do
    source = data["path"] || "memory"

    case {data["line_start"], data["line_end"]} do
      {start_line, end_line} when is_integer(start_line) and is_integer(end_line) ->
        "#{source}#L#{start_line}-L#{end_line}"

      {start_line, _} when is_integer(start_line) ->
        "#{source}#L#{start_line}"

      _ ->
        source
    end
  end

  defp rank_memory_score(%Node{} = node, base_score), do: rank_memory_score(base_score, node.data)
  defp rank_memory_score(base_score, %Node{} = node), do: rank_memory_score(node, base_score)

  defp rank_memory_score(base_score, data) when is_map(data) do
    importance_boost = (data["importance"] || 5) / 10
    access_boost = (data["access_count"] || 0) * 0.05

    recency_boost =
      case data["last_accessed_at"] || data["inserted_at"] do
        nil -> 0.0
        _ -> 0.05
      end

    base_score + importance_boost + access_boost + recency_boost
  end

  defp extract_session_id("session:" <> rest) do
    rest
    |> String.split(":", parts: 3)
    |> hd()
  end

  defp extract_session_id(_), do: "unknown"

  defp search_documents_sql(ts_query, limit, opts) do
    include_forgotten = Keyword.get(opts, :include_forgotten, false)

    {clauses, params, next_index} =
      add_optional_clause(
        [
          "n.type = 'document'",
          "to_tsvector('simple', COALESCE(n.data->>'content', '')) @@ websearch_to_tsquery('simple', $1)"
        ],
        [ts_query, limit],
        3,
        Keyword.get(opts, :memory_type),
        fn type, idx -> {"n.data->>'memory_type' = $#{idx}", MemoryTypes.normalize(type)} end
      )

    {clauses, params, _next_index} =
      add_optional_clause(
        clauses,
        params,
        next_index,
        Keyword.get(opts, :session_id),
        fn session_id, idx -> {"n.data->>'session_id' = $#{idx}", session_id} end
      )

    clauses =
      if include_forgotten,
        do: clauses,
        else: clauses ++ ["COALESCE(n.data->>'forgotten_at', '') = ''"]

    sql = """
    SELECT n.id::text,
           ts_rank_cd(
             to_tsvector('simple', COALESCE(n.data->>'content', '')),
             websearch_to_tsquery('simple', $1)
           ) AS score
    FROM nodes AS n
    WHERE #{Enum.join(clauses, " AND ")}
    ORDER BY score DESC, n.inserted_at DESC
    LIMIT $2
    """

    {sql, params}
  end

  defp add_optional_clause(clauses, params, next_index, nil, _builder),
    do: {clauses, params, next_index}

  defp add_optional_clause(clauses, params, next_index, value, builder) do
    {clause, param} = builder.(value, next_index)
    {clauses ++ [clause], params ++ [param], next_index + 1}
  end
end
