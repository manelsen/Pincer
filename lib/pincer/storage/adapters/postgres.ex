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
  def search_graph_history(query, limit \\ 5) do
    tokens = search_tokens(query)

    if tokens == [] do
      {:ok, []}
    else
      query =
        from(b in Node,
          join: occurs in Edge,
          on: occurs.from_id == b.id and occurs.type == "occurs_in",
          join: f in Node,
          on: f.id == occurs.to_id and f.type == "file",
          left_join: solves in Edge,
          on: solves.to_id == b.id and solves.type == "solves",
          left_join: fx in Node,
          on: fx.id == solves.from_id and fx.type == "fix",
          where: b.type == "bug",
          select: %{
            bug: fragment("COALESCE(?->>'description', '')", b.data),
            fix: fragment("COALESCE(?->>'summary', '')", fx.data),
            file: fragment("COALESCE(?->>'path', '')", f.data)
          }
        )

      {:ok,
       query
       |> Repo.all()
       |> Enum.map(&graph_history_result(&1, tokens))
       |> Enum.filter(&(&1.score > 0.0))
       |> Enum.sort_by(&{-&1.score, &1.file})
       |> Enum.uniq_by(&{&1.bug, &1.fix, &1.file})
       |> Enum.take(limit)}
    end
  end

  @impl true
  def memory_report(limit \\ 5) do
    {:ok,
     %{
       total_documents: total_documents(),
       forgotten_documents: forgotten_documents(),
       by_type: memory_counts_by_type(),
       top_documents: top_documents(limit),
       top_sessions: top_sessions(limit)
     }}
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
         scoring = score_document(node, :semantic, 1.0 - distance, [])
         touch_memory_access(node)
         document_result(node, scoring)
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

        query_tokens = search_tokens(query)

        case Ecto.Adapters.SQL.query(Repo, sql, params) do
          {:ok, %{rows: rows}} ->
            results =
              rows
              |> Enum.map(fn [node_id, score] ->
                node = Repo.get!(Node, node_id)
                scoring = score_document(node, :text, score, query_tokens)
                touch_memory_access(node)
                {node, scoring}
              end)
              |> Enum.sort_by(
                fn {node, scoring} -> {scoring.score, node.inserted_at} end,
                :desc
              )
              |> Enum.map(fn {node, scoring} ->
                document_result(node, scoring)
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
        signal_score =
          tokens
          |> Enum.count(&String.contains?(String.downcase(node.data["content"] || ""), &1))
          |> Kernel./(max(length(tokens), 1))

        scoring = score_document(node, :text, signal_score, tokens)

        touch_memory_access(node)
        document_result(node, scoring)
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

  defp document_result(node, scoring) do
    %{
      kind: :document,
      role: "document",
      content: node.data["content"],
      source: node.data["path"],
      citation: build_citation(node.data),
      score: scoring.score,
      signal: scoring.signal,
      signal_score: scoring.signal_score,
      signals: [scoring.signal],
      score_components: scoring.score_components,
      memory_type: node.data["memory_type"] || "reference",
      importance: node.data["importance"] || 5,
      access_count: (node.data["access_count"] || 0) + 1,
      session_id: node.data["session_id"],
      forgotten?: memory_forgotten?(node.data)
    }
  end

  defp total_documents do
    from(n in Node, where: n.type == "document", select: count(n.id))
    |> Repo.one()
  end

  defp forgotten_documents do
    from(n in Node,
      where: n.type == "document",
      where: fragment("COALESCE(?->>'forgotten_at', '') <> ''", n.data),
      select: count(n.id)
    )
    |> Repo.one()
  end

  defp memory_counts_by_type do
    from(n in Node,
      where: n.type == "document",
      group_by: fragment("COALESCE(?->>'memory_type', 'reference')", n.data),
      select: {fragment("COALESCE(?->>'memory_type', 'reference')", n.data), count(n.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp top_documents(limit) do
    from(n in Node,
      where: n.type == "document",
      order_by: [
        desc: fragment("COALESCE((?->>'access_count')::int, 0)", n.data),
        desc: fragment("COALESCE((?->>'importance')::int, 0)", n.data),
        desc: n.inserted_at
      ],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(fn node ->
      %{
        source: node.data["path"],
        memory_type: node.data["memory_type"] || "reference",
        importance: node.data["importance"] || 5,
        access_count: node.data["access_count"] || 0,
        session_id: node.data["session_id"],
        forgotten?: memory_forgotten?(node.data),
        citation: build_citation(node.data)
      }
    end)
  end

  defp top_sessions(limit) do
    from(n in Node,
      where: n.type == "document",
      where: fragment("COALESCE(?->>'session_id', '') <> ''", n.data),
      group_by: fragment("?->>'session_id'", n.data),
      order_by: [
        desc: count(n.id),
        asc: fragment("?->>'session_id'", n.data)
      ],
      limit: ^limit,
      select: {fragment("?->>'session_id'", n.data), count(n.id)}
    )
    |> Repo.all()
    |> Enum.map(fn {session_id, document_count} ->
      %{session_id: session_id, document_count: document_count}
    end)
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

  defp score_document(%Node{} = node, signal, raw_signal_score, query_tokens) do
    signal_score = normalize_signal_score(signal, raw_signal_score)
    metadata = metadata_boosts(node, query_tokens)

    %{
      score: signal_score + metadata.total,
      signal: signal,
      signal_score: signal_score,
      score_components:
        metadata.components
        |> Map.put(signal, signal_score)
        |> Map.put(:metadata_total, metadata.total)
    }
  end

  defp normalize_signal_score(:text, score) do
    score
    |> Kernel.*(20.0)
    |> clamp_score()
  end

  defp normalize_signal_score(:semantic, score), do: clamp_score(score)

  defp normalize_signal_score(_signal, score), do: clamp_score(score)

  defp clamp_score(score) when is_number(score), do: min(1.0, max(0.0, score * 1.0))
  defp clamp_score(_score), do: 0.0

  defp metadata_boosts(node, query_tokens) do
    importance = min(0.35, (node.data["importance"] || 5) / 10 * 0.35)

    access =
      node.data["access_count"]
      |> Kernel.||(0)
      |> Kernel.+(1)
      |> :math.log10()
      |> Kernel.*(0.12)
      |> min(0.18)

    freshness = freshness_boost(node)
    graph = graph_boost(node, query_tokens)
    total = importance + access + freshness + graph

    %{
      total: total,
      components: %{
        importance: importance,
        access: access,
        freshness: freshness,
        graph: graph
      }
    }
  end

  defp freshness_boost(node) do
    timestamp =
      parse_timestamp(node.data["last_accessed_at"]) || naive_to_datetime(node.inserted_at)

    case timestamp do
      nil ->
        0.0

      datetime ->
        age_days = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0) / 86_400
        0.18 * :math.exp(-age_days / 30)
    end
  end

  defp graph_boost(node, query_tokens) do
    path = node.data["path"]

    if is_binary(path) do
      {bug_count, fix_count, overlap_count} = graph_signal_for_path(path, query_tokens)

      incident_bonus =
        if incident_query?(query_tokens) and (bug_count > 0 or fix_count > 0), do: 0.05, else: 0.0

      overlap_bonus = min(0.08, overlap_count * 0.04)

      boost =
        0.18 + min(0.12, bug_count * 0.10) + min(0.15, fix_count * 0.15) + incident_bonus +
          overlap_bonus

      if bug_count > 0 or fix_count > 0, do: min(0.45, boost), else: 0.0
    else
      0.0
    end
  end

  defp graph_signal_for_path(path, query_tokens) do
    case find_node_by_path("file", path) do
      nil ->
        {0, 0, 0}

      file_node ->
        bug_nodes =
          from(b in Node,
            join: e in Edge,
            on: e.from_id == b.id,
            where: e.to_id == ^file_node.id and e.type == "occurs_in" and b.type == "bug"
          )
          |> Repo.all()

        bug_ids = Enum.map(bug_nodes, & &1.id)

        fix_nodes =
          if bug_ids == [] do
            []
          else
            from(f in Node,
              join: e in Edge,
              on: e.from_id == f.id,
              where: e.to_id in ^bug_ids and e.type == "solves" and f.type == "fix"
            )
            |> Repo.all()
          end

        overlap_count =
          (Enum.map(bug_nodes, &(&1.data["description"] || "")) ++
             Enum.map(fix_nodes, &(&1.data["summary"] || "")))
          |> Enum.join(" ")
          |> String.downcase()
          |> then(fn graph_text ->
            Enum.count(query_tokens, &String.contains?(graph_text, &1))
          end)

        {length(bug_nodes), length(fix_nodes), overlap_count}
    end
  end

  defp graph_history_result(%{bug: bug, fix: fix, file: file}, query_tokens) do
    graph_text = Enum.join([bug, fix, file], " ") |> String.downcase()
    overlap = Enum.count(query_tokens, &String.contains?(graph_text, &1))
    normalized = overlap / max(length(query_tokens), 1)
    incident_bonus = if incident_query?(query_tokens), do: 0.1, else: 0.0
    score = min(1.0, normalized + incident_bonus)

    %{
      kind: :graph,
      bug: bug,
      fix: fix,
      file: file,
      content: "Bug: #{bug}. Fix: #{fix}. File: #{file}",
      source: "graph://#{file}",
      citation: "graph #{file}",
      score: score
    }
  end

  defp incident_query?(tokens) do
    Enum.any?(
      tokens,
      &(&1 in ["bug", "fix", "timeout", "incident", "deploy", "retry", "retries"])
    )
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_timestamp(_value), do: nil

  defp naive_to_datetime(nil), do: nil

  defp naive_to_datetime(%NaiveDateTime{} = datetime),
    do: DateTime.from_naive!(datetime, "Etc/UTC")

  defp naive_to_datetime(_value), do: nil

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
