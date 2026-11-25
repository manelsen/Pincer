defmodule Pincer.Adapters.Storage.SQLite do
  @moduledoc """
  Unified zero-infrastructure SQLite storage adapter implementing `Pincer.Ports.Storage`.

  Provides the embedded storage backend via `Pincer.Infra.SQLite`
  (Exqlite + WAL + FTS5) with:
  - Message persistence and FTS5 full-text search (plus safe substring fallback)
  - JSON-backed graph nodes and edges (bug fixes, decisions, patterns, entities)
  - Learning and tool-error deduplication (`pattern_key`)
  - Document/memory indexing with FTS5 search, metadata scoring, soft forget, and reports
  - `search_similar/3` through the optional `sqlite-vec` `vec0` KNN index, with
    pure-Elixir cosine similarity as the fallback when the extension is absent
  - Binary checkpoint snapshots and durable pairing state persistence
  """

  @behaviour Pincer.Ports.Storage

  require Logger

  alias Pincer.Adapters.Storage.MemoryHelpers
  alias Pincer.Infra.SQLite
  alias Pincer.Adapters.Storage.Checkpoint

  @project_statuses ~w(planning awaiting_approval running paused error completed stopped)

  # --- Messages ---

  @impl true
  @spec get_messages(String.t()) :: [map()]
  def get_messages(session_id) do
    case SQLite.query(
           SQLite.default_server(),
           "SELECT role, content FROM messages WHERE session_id = ?1 ORDER BY id ASC",
           [to_string(session_id)]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [role, content] -> %{role: role, content: content} end)

      {:error, _} ->
        []
    end
  end

  @impl true
  @spec save_message(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def save_message(session_id, role, content) do
    now = now_iso8601()
    sid = to_string(session_id)
    role_str = to_string(role)
    content_str = to_string(content)

    case SQLite.execute(
           SQLite.default_server(),
           "INSERT INTO messages (session_id, role, content, inserted_at) VALUES (?1, ?2, ?3, ?4)",
           [sid, role_str, content_str, now]
         ) do
      :ok -> {:ok, %{session_id: sid, role: role_str, content: content_str, inserted_at: now}}
      error -> error
    end
  end

  @impl true
  @spec delete_messages(String.t()) :: :ok | {:error, term()}
  def delete_messages(session_id) do
    SQLite.execute(
      SQLite.default_server(),
      "DELETE FROM messages WHERE session_id = ?1",
      [to_string(session_id)]
    )
  end

  # --- Graph Knowledge ---

  @impl true
  @spec ingest_bug_fix(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def ingest_bug_fix(bug_desc, fix_summary, file_path) do
    SQLite.transaction(SQLite.default_server(), fn tx ->
      with {:ok, file_node} <- ensure_node(tx, "file", %{"path" => file_path}),
           {:ok, bug_node} <- create_node(tx, "bug", %{"description" => bug_desc}),
           {:ok, fix_node} <- create_node(tx, "fix", %{"summary" => fix_summary}),
           :ok <- create_edge(tx, bug_node.id, file_node.id, "occurs_in"),
           :ok <- create_edge(tx, fix_node.id, bug_node.id, "solves") do
        :ok
      end
    end)
  end

  @impl true
  @spec query_history() :: [map()]
  def query_history do
    server = SQLite.default_server()

    case SQLite.query(
           server,
           "SELECT id, data FROM nodes WHERE type = 'bug' ORDER BY inserted_at DESC LIMIT 10"
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [bug_id, bug_json] ->
          bug_data = decode_json(bug_json)
          file = find_connected_node(server, bug_id, "occurs_in", "file")
          fix = find_connected_rev_node(server, bug_id, "solves", "fix")

          %{
            bug: bug_data["description"],
            file: if(file, do: file.data["path"], else: "unknown"),
            fix: if(fix, do: fix.data["summary"], else: "no fix recorded")
          }
        end)

      {:error, _} ->
        []
    end
  end

  @impl true
  @spec ingest_decision(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def ingest_decision(topic, rationale, affects_file \\ nil) do
    data = %{"topic" => topic, "rationale" => rationale, "timestamp" => now_iso8601()}

    SQLite.transaction(SQLite.default_server(), fn tx ->
      with {:ok, decision_node} <- create_node(tx, "decision", data) do
        if is_binary(affects_file) and affects_file != "" do
          with {:ok, file_node} <- ensure_node(tx, "file", %{"path" => affects_file}) do
            create_edge(tx, decision_node.id, file_node.id, "affects")
          end
        else
          :ok
        end
      end
    end)
  end

  @impl true
  @spec ingest_pattern(String.t(), String.t()) :: :ok | {:error, term()}
  def ingest_pattern(name, description) do
    data = %{"name" => name, "description" => description, "timestamp" => now_iso8601()}

    case create_node(SQLite.default_server(), "pattern", data) do
      {:ok, _node} -> :ok
      error -> error
    end
  end

  @impl true
  @spec ingest_person(String.t(), map()) :: :ok | {:error, term()}
  def ingest_person(name, attrs \\ %{}) do
    data = Map.merge(%{"name" => name, "timestamp" => now_iso8601()}, stringify_keys(attrs))

    case find_or_create_entity(SQLite.default_server(), "person", name, data) do
      {:ok, _node} -> :ok
      error -> error
    end
  end

  @impl true
  @spec ingest_animal(String.t(), String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def ingest_animal(name, species \\ nil, notes \\ nil) do
    data =
      %{"name" => name, "timestamp" => now_iso8601()}
      |> maybe_put("species", species)
      |> maybe_put("notes", notes)

    case find_or_create_entity(SQLite.default_server(), "animal", name, data) do
      {:ok, _node} -> :ok
      error -> error
    end
  end

  @impl true
  @spec ingest_entity_relation(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def ingest_entity_relation(from_name, from_type, relation, to_name, to_type) do
    SQLite.transaction(SQLite.default_server(), fn tx ->
      with {:ok, from_node} <-
             find_or_create_entity(tx, from_type, from_name, %{"name" => from_name}),
           {:ok, to_node} <- find_or_create_entity(tx, to_type, to_name, %{"name" => to_name}) do
        case find_edge(tx, from_node.id, to_node.id, relation) do
          nil -> create_edge(tx, from_node.id, to_node.id, relation)
          _existing -> :ok
        end
      end
    end)
  end

  # --- Learnings & Tool Errors ---

  @impl true
  @spec save_learning(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def save_learning(category, summary) do
    pattern_key = build_pattern_key(category, summary)
    now = now_iso8601()
    server = SQLite.default_server()

    case find_node_by_pattern_key(server, pattern_key) do
      nil ->
        data = %{
          "category" => category,
          "summary" => summary,
          "timestamp" => now,
          "structured_id" => build_structured_id("LRN", summary),
          "pattern_key" => pattern_key,
          "recurrence_count" => 1,
          "first_seen_at" => now,
          "last_seen_at" => now
        }

        create_node(server, "learning", data)

      existing ->
        next_count = (existing.data["recurrence_count"] || 1) + 1

        next_data =
          existing.data
          |> Map.put("recurrence_count", next_count)
          |> Map.put("last_seen_at", now)

        update_node_data(server, existing.id, next_data)
    end
  end

  @impl true
  @spec save_tool_error(String.t(), map(), term()) :: {:ok, map()} | {:error, term()}
  def save_tool_error(tool, args, error) do
    summary = to_string(error)
    pattern_key = build_pattern_key(tool, summary)
    now = now_iso8601()
    server = SQLite.default_server()

    case find_node_by_pattern_key(server, pattern_key) do
      nil ->
        data = %{
          "tool" => tool,
          "args" => args,
          "error" => error,
          "timestamp" => now,
          "structured_id" => build_structured_id("ERR", summary),
          "pattern_key" => pattern_key,
          "recurrence_count" => 1,
          "first_seen_at" => now,
          "last_seen_at" => now
        }

        create_node(server, "tool_error", data)

      existing ->
        next_count = (existing.data["recurrence_count"] || 1) + 1

        next_data =
          existing.data
          |> Map.put("recurrence_count", next_count)
          |> Map.put("last_seen_at", now)

        update_node_data(server, existing.id, next_data)
    end
  end

  @impl true
  @spec list_recent_learnings(integer()) :: [map()]
  def list_recent_learnings(limit \\ 3) do
    case SQLite.query(
           SQLite.default_server(),
           """
           SELECT type, data
           FROM nodes
           WHERE type IN ('tool_error', 'learning')
           ORDER BY inserted_at DESC
           LIMIT ?1
           """,
           [limit]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [type, json] ->
          data = decode_json(json)

          case type do
            "tool_error" -> %{type: :error, tool: data["tool"], error: data["error"]}
            "learning" -> %{type: :learning, category: data["category"], summary: data["summary"]}
          end
        end)

      {:error, _} ->
        []
    end
  end

  # --- Documents & Memory Search ---

  @impl true
  @spec get_document_metadata(String.t(), String.t() | nil) :: map() | nil
  def get_document_metadata(path, workspace_root) do
    case find_node_by_path(SQLite.default_server(), "document", path, workspace_root) do
      nil -> nil
      node -> node.data
    end
  end

  @impl true
  @spec index_document(String.t(), String.t(), [float()], map()) :: :ok | {:error, term()}
  def index_document(path, content, vector, metadata \\ %{}) do
    normalized_opts =
      Enum.reduce(metadata, [], fn
        {:workspace_root, v}, acc -> [{:workspace_root, v} | acc]
        {"workspace_root", v}, acc -> [{:workspace_root, v} | acc]
        {:session_id, v}, acc -> [{:session_id, v} | acc]
        {"session_id", v}, acc -> [{:session_id, v} | acc]
        {:importance, v}, acc -> [{:importance, v} | acc]
        {"importance", v}, acc -> [{:importance, v} | acc]
        {:line_start, v}, acc -> [{:line_start, v} | acc]
        {"line_start", v}, acc -> [{:line_start, v} | acc]
        {:line_end, v}, acc -> [{:line_end, v} | acc]
        {"line_end", v}, acc -> [{:line_end, v} | acc]
        {:memory_type, v}, acc -> [{:memory_type, v} | acc]
        {"memory_type", v}, acc -> [{:memory_type, v} | acc]
        _, acc -> acc
      end)

    memory_type = Keyword.get(normalized_opts, :memory_type, "reference")
    index_memory(path, content, memory_type, vector, normalized_opts)
  end

  @impl true
  @spec index_memory(String.t(), String.t(), String.t(), [float()], keyword()) ::
          :ok | {:error, term()}
  def index_memory(path, content, memory_type, vector, opts \\ []) do
    metadata = build_memory_metadata(path, content, memory_type, opts)
    workspace_root = Keyword.get(opts, :workspace_root)
    embedding_json = if is_list(vector), do: Jason.encode!(vector), else: nil

    SQLite.transaction(SQLite.default_server(), fn tx ->
      case find_node_by_path(tx, "document", path, workspace_root) do
        nil ->
          with {:ok, node} <- create_node(tx, "document", metadata, embedding_json),
               :ok <- upsert_document_fts(tx, node.id, content, path),
               :ok <- sync_vec_node(tx, node.id, vector) do
            :ok
          end

        existing ->
          now = now_iso8601()

          with :ok <-
                 SQLite.execute(
                   tx,
                   """
                   UPDATE nodes
                   SET data = ?1, embedding = ?2, updated_at = ?3
                   WHERE id = ?4
                   """,
                   [Jason.encode!(metadata), embedding_json, now, existing.id]
                 ),
               :ok <- upsert_document_fts(tx, existing.id, content, path),
               :ok <- sync_vec_node(tx, existing.id, vector) do
            :ok
          end
      end
    end)
  end

  @impl true
  @spec search_messages(String.t(), integer()) :: {:ok, [map()]} | {:error, term()}
  def search_messages(query, limit \\ 5) do
    case search_messages_fts(query, limit) do
      {:ok, []} -> fallback_search_messages(query, limit)
      {:ok, _} = ok -> ok
      {:error, _} -> fallback_search_messages(query, limit)
    end
  end

  @impl true
  @spec search_documents(String.t(), integer()) :: {:ok, [map()]} | {:error, term()}
  def search_documents(query, limit \\ 5), do: search_documents(query, limit, [])

  @impl true
  @spec search_documents(String.t(), integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search_documents(query, limit, opts) do
    case search_documents_fts(query, limit, opts) do
      {:ok, []} -> fallback_search_documents(query, limit, opts)
      {:ok, _} = ok -> ok
      {:error, _} -> fallback_search_documents(query, limit, opts)
    end
  end

  @impl true
  @spec search_sessions(String.t(), integer()) :: {:ok, [map()]} | {:error, term()}
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
  @spec search_graph_history(String.t(), integer()) :: {:ok, [map()]} | {:error, term()}
  def search_graph_history(query, limit \\ 5) do
    tokens = search_tokens(query)

    if tokens == [] do
      {:ok, []}
    else
      server = SQLite.default_server()
      bug_hits = search_bug_fix_nodes(server, tokens, limit)
      knowledge_hits = search_knowledge_nodes(server, tokens, limit)

      {:ok,
       (bug_hits ++ knowledge_hits)
       |> Enum.filter(&(&1.score > 0.3))
       |> Enum.sort_by(&(-&1.score))
       |> Enum.uniq_by(&Map.get(&1, :content, ""))
       |> Enum.take(limit)}
    end
  end

  @impl true
  @spec memory_report(integer()) :: {:ok, map()} | {:error, term()}
  def memory_report(limit \\ 5) do
    case SQLite.query(
           SQLite.default_server(),
           "SELECT id, data, access_count, inserted_at FROM nodes WHERE type = 'document'"
         ) do
      {:ok, %{rows: rows}} ->
        nodes =
          Enum.map(rows, fn [id, json, access_count, inserted_at] ->
            %{
              id: id,
              data: decode_json(json),
              access_count: access_count || 0,
              inserted_at: inserted_at
            }
          end)

        forgotten = Enum.count(nodes, &memory_forgotten?(&1.data))

        by_type =
          Enum.reduce(nodes, %{}, fn node, acc ->
            mtype = node.data["memory_type"] || "reference"
            Map.update(acc, mtype, 1, &(&1 + 1))
          end)

        top_documents =
          nodes
          |> Enum.sort_by(
            fn node ->
              {
                node.data["access_count"] || 0,
                node.data["importance"] || 5,
                node.inserted_at
              }
            end,
            :desc
          )
          |> Enum.take(limit)
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

        top_sessions =
          nodes
          |> Enum.filter(fn n ->
            sid = n.data["session_id"]
            is_binary(sid) and sid != ""
          end)
          |> Enum.group_by(& &1.data["session_id"])
          |> Enum.map(fn {sid, list} -> %{session_id: sid, document_count: length(list)} end)
          |> Enum.sort_by(&{-&1.document_count, &1.session_id})
          |> Enum.take(limit)

        {:ok,
         %{
           total_documents: length(nodes),
           forgotten_documents: forgotten,
           by_type: by_type,
           top_documents: top_documents,
           top_sessions: top_sessions
         }}

      error ->
        error
    end
  end

  @impl true
  @spec forget_memory(String.t()) :: :ok | {:error, term()}
  def forget_memory(source) do
    server = SQLite.default_server()

    case find_node_by_path(server, "document", source, nil) do
      nil ->
        {:error, :not_found}

      node ->
        next_data = Map.put(node.data, "forgotten_at", now_iso8601())

        with {:ok, _} <- update_node_data(server, node.id, next_data),
             :ok <- sync_vec_node(server, node.id, nil) do
          :ok
        end
    end
  end

  @impl true
  @spec search_similar(String.t(), [float()], integer()) :: {:ok, [map()]} | {:error, term()}
  def search_similar(type, query_vector, limit \\ 5) do
    case search_similar_vec(type, query_vector, limit) do
      {:ok, []} -> search_similar_cosine(type, query_vector, limit)
      {:error, _reason} -> search_similar_cosine(type, query_vector, limit)
      result -> result
    end
  end

  defp search_similar_vec(type, query_vector, limit) do
    server = SQLite.default_server()

    with true <- SQLite.vec_enabled?(server),
         true <- valid_vector?(query_vector) do
      candidates = max(limit * 10, 50)

      case SQLite.query(
             server,
             """
             SELECT n.id, n.data, n.access_count, n.inserted_at, v.distance
             FROM (
               SELECT rowid, distance
               FROM vec_nodes
               WHERE embedding MATCH ?1
               ORDER BY distance
               LIMIT ?2
             ) AS v
             JOIN nodes AS n ON n.rowid = v.rowid
             WHERE n.type = ?3
               AND COALESCE(json_extract(n.data, '$.forgotten_at'), '') = ''
             ORDER BY v.distance
             LIMIT ?4
             """,
             [Jason.encode!(query_vector), candidates, type, limit]
           ) do
        {:ok, %{rows: rows}} ->
          results =
            Enum.map(rows, fn [id, json, access_count, inserted_at, distance] ->
              node = %{
                id: id,
                data: decode_json(json),
                access_count: access_count || 0,
                inserted_at: inserted_at
              }

              similarity = 1.0 - distance
              scoring = score_document(server, node, :semantic, similarity, [])

              result =
                node
                |> Map.put(:access_count, access_count || 0)
                |> document_result(scoring)

              touch_memory_access(server, node)
              result
            end)

          {:ok, results}

        error ->
          error
      end
    else
      false -> {:ok, []}
    end
  end

  defp search_similar_cosine(type, query_vector, limit) do
    server = SQLite.default_server()

    case SQLite.query(
           server,
           """
           SELECT id, data, embedding, access_count, inserted_at
           FROM nodes
           WHERE type = ?1
             AND embedding IS NOT NULL
             AND COALESCE(json_extract(data, '$.forgotten_at'), '') = ''
           """,
           [type]
         ) do
      {:ok, %{rows: rows}} ->
        results =
          rows
          |> Enum.map(fn [id, json, emb_json, access_count, inserted_at] ->
            node = %{
              id: id,
              data: decode_json(json),
              access_count: access_count || 0,
              inserted_at: inserted_at
            }

            vec = decode_embedding(emb_json)
            sim = cosine_similarity(query_vector, vec)
            {node, sim}
          end)
          |> Enum.sort_by(fn {node, sim} -> {sim, node.inserted_at} end, :desc)
          |> Enum.take(limit)
          |> Enum.map(fn {node, sim} ->
            scoring = score_document(server, node, :semantic, sim, [])
            touch_memory_access(server, node)
            document_result(node, scoring)
          end)

        {:ok, results}

      error ->
        error
    end
  end

  @impl true
  @spec purge_invalid_documents([String.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def purge_invalid_documents(prefixes \\ ["tmp/", "workspaces/"]) when is_list(prefixes) do
    case like_prefix_patterns(prefixes) do
      [] ->
        {:ok, 0}

      patterns ->
        clauses =
          patterns
          |> Enum.with_index(1)
          |> Enum.map_join(" OR ", fn {_pat, idx} ->
            "json_extract(data, '$.path') LIKE ?#{idx} ESCAPE '!'"
          end)

        select_sql = "SELECT id FROM nodes WHERE type = 'document' AND (#{clauses})"

        SQLite.transaction(SQLite.default_server(), fn tx ->
          with {:ok, %{rows: rows}} <- SQLite.query(tx, select_sql, patterns),
               ids <- Enum.map(rows, fn [id] -> id end),
               :ok <- delete_document_ids(tx, ids) do
            {:ok, length(ids)}
          end
        end)
    end
  end

  @doc """
  Filters non-empty string prefixes and converts them into SQL `LIKE` patterns
  escaped with `'!'` (`!`, `%`, `_`).
  """
  @spec like_prefix_patterns([String.t()]) :: [String.t()]
  def like_prefix_patterns(prefixes) when is_list(prefixes) do
    prefixes
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(fn prefix ->
      escaped =
        prefix
        |> String.replace("!", "!!")
        |> String.replace("%", "!%")
        |> String.replace("_", "!_")

      escaped <> "%"
    end)
  end

  defp delete_vec_nodes(_tx, []), do: :ok

  defp delete_vec_nodes(tx, ids) do
    if SQLite.vec_enabled?(tx) do
      placeholders = Enum.map_join(1..length(ids), ", ", &"?#{&1}")

      SQLite.execute(
        tx,
        "DELETE FROM vec_nodes WHERE rowid IN (SELECT rowid FROM nodes WHERE id IN (#{placeholders}))",
        ids
      )
    else
      :ok
    end
  end

  defp delete_document_ids(_tx, []), do: :ok

  defp delete_document_ids(tx, ids) do
    ids
    |> Enum.chunk_every(200)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      placeholders =
        1..length(chunk)
        |> Enum.map_join(", ", &"?#{&1}")

      with :ok <-
             SQLite.execute(
               tx,
               "DELETE FROM documents_fts WHERE node_id IN (#{placeholders})",
               chunk
             ),
           :ok <- delete_vec_nodes(tx, chunk),
           :ok <-
             SQLite.execute(
               tx,
               "DELETE FROM nodes WHERE id IN (#{placeholders})",
               chunk
             ) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  # --- Checkpoints ---

  @impl true
  @spec save_checkpoint(String.t(), map()) :: {:ok, Checkpoint.t()} | {:error, term()}
  def save_checkpoint(session_id, checkpoint) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    now_str = DateTime.to_iso8601(now)
    id = SQLite.uuid()
    sid = to_string(session_id)
    status = to_string(Map.get(checkpoint, :status, Map.get(checkpoint, "status", "running")))

    snapshot =
      Map.get(checkpoint, :history_snapshot, Map.get(checkpoint, "history_snapshot", <<>>))

    step_count = Map.get(checkpoint, :step_count, Map.get(checkpoint, "step_count", 0))
    task_id = Map.get(checkpoint, :task_id, Map.get(checkpoint, "task_id"))
    project_id = Map.get(checkpoint, :project_id, Map.get(checkpoint, "project_id"))
    metadata = Map.get(checkpoint, :metadata, Map.get(checkpoint, "metadata", %{}))

    SQLite.transaction(SQLite.default_server(), fn tx ->
      with :ok <-
             SQLite.execute(
               tx,
               """
               UPDATE checkpoints
               SET status = 'paused', updated_at = ?1
               WHERE session_id = ?2 AND status IN ('running', 'paused')
               """,
               [now_str, sid]
             ),
           :ok <-
             SQLite.execute(
               tx,
               """
               INSERT INTO checkpoints
                 (id, session_id, task_id, project_id, status, history_snapshot, step_count, metadata, inserted_at, updated_at)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
               """,
               [
                 id,
                 sid,
                 task_id,
                 project_id,
                 status,
                 {:blob, snapshot},
                 step_count,
                 Jason.encode!(metadata || %{}),
                 now_str,
                 now_str
               ]
             ) do
        {:ok,
         %Checkpoint{
           id: id,
           session_id: sid,
           task_id: task_id,
           project_id: project_id,
           status: status,
           history_snapshot: snapshot,
           step_count: step_count,
           metadata: metadata || %{},
           inserted_at: now,
           updated_at: now
         }}
      end
    end)
  end

  @impl true
  @spec load_checkpoint(String.t(), keyword()) :: {:ok, Checkpoint.t()} | {:error, term()}
  def load_checkpoint(session_id, opts \\ []) do
    with {:ok, statuses} <- checkpoint_statuses(opts) do
      placeholders =
        statuses
        |> Enum.with_index(2)
        |> Enum.map_join(", ", fn {_status, index} -> "?#{index}" end)

      query = """
      SELECT id, session_id, task_id, project_id, status, history_snapshot, step_count, metadata, inserted_at, updated_at
      FROM checkpoints
      WHERE session_id = ?1 AND status IN (#{placeholders})
      ORDER BY inserted_at DESC, rowid DESC
      LIMIT 1
      """

      case SQLite.query(SQLite.default_server(), query, [to_string(session_id) | statuses]) do
        {:ok,
         %{
           rows: [
             [
               id,
               sid,
               task_id,
               project_id,
               status,
               snapshot,
               step_count,
               meta_json,
               inserted_at,
               updated_at
             ]
           ]
         }} ->
          {:ok,
           %Checkpoint{
             id: id,
             session_id: sid,
             task_id: task_id,
             project_id: project_id,
             status: status,
             history_snapshot: snapshot,
             step_count: step_count,
             metadata: decode_json(meta_json),
             inserted_at: parse_timestamp(inserted_at),
             updated_at: parse_timestamp(updated_at)
           }}

        _ ->
          {:error, :not_found}
      end
    end
  end

  defp checkpoint_statuses(opts) do
    statuses =
      (opts[:status] || ["running", "paused"])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    if statuses != [] and Enum.all?(statuses, &(&1 in Checkpoint.valid_statuses())) do
      {:ok, statuses}
    else
      {:error, :invalid_status}
    end
  end

  # --- Durable Projects ---

  @impl true
  @spec save_project(map()) :: :ok | {:error, term()}
  def save_project(project) when is_map(project) do
    with {:ok, id} <- project_string(project, :id),
         {:ok, session_id} <- project_string(project, :session_id),
         {:ok, kind} <- project_string(project, :kind),
         {:ok, status} <- project_status(project),
         {:ok, payload} <- project_payload(project) do
      now = now_iso8601()

      SQLite.execute(
        SQLite.default_server(),
        """
        INSERT INTO projects (id, session_id, kind, status, payload, inserted_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        ON CONFLICT(id) DO UPDATE SET
          session_id = excluded.session_id,
          kind = excluded.kind,
          status = excluded.status,
          payload = excluded.payload,
          updated_at = excluded.updated_at
        """,
        [id, session_id, kind, status, {:blob, payload}, now, now]
      )
    end
  end

  @impl true
  @spec load_project(String.t()) :: {:ok, map()} | {:error, term()}
  def load_project(id) when is_binary(id) do
    case SQLite.query(
           SQLite.default_server(),
           "SELECT id, session_id, kind, status, payload, inserted_at, updated_at FROM projects WHERE id = ?1",
           [id]
         ) do
      {:ok, %{rows: [row]}} -> project_from_row(row)
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec list_projects(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_projects(opts \\ []) when is_list(opts) do
    with {:ok, statuses} <- project_statuses(opts),
         {:ok, limit} <- project_limit(opts) do
      {where, params} = project_filters(opts, statuses)

      query = """
      SELECT id, session_id, kind, status, payload, inserted_at, updated_at
      FROM projects
      #{where}
      ORDER BY updated_at DESC
      LIMIT ?#{length(params) + 1}
      """

      case SQLite.query(SQLite.default_server(), query, params ++ [limit]) do
        {:ok, %{rows: rows}} ->
          rows
          |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
            case project_from_row(row) do
              {:ok, project} -> {:cont, {:ok, [project | acc]}}
              error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, projects} -> {:ok, Enum.reverse(projects)}
            error -> error
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  @spec delete_project(String.t()) :: :ok | {:error, term()}
  def delete_project(id) when is_binary(id) do
    SQLite.execute(SQLite.default_server(), "DELETE FROM projects WHERE id = ?1", [id])
  end

  @impl true
  @spec delete_projects_by_kind(String.t()) :: :ok | {:error, term()}
  def delete_projects_by_kind(kind) when is_binary(kind) do
    SQLite.execute(SQLite.default_server(), "DELETE FROM projects WHERE kind = ?1", [kind])
  end

  defp project_string(project, key) do
    case Map.get(project, key, Map.get(project, Atom.to_string(key))) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_project, key}}
    end
  end

  defp project_status(project) do
    status = Map.get(project, :status, Map.get(project, "status", "planning"))
    status_string = to_string(status)

    if status_string in @project_statuses do
      {:ok, status_string}
    else
      {:error, {:invalid_project_status, status}}
    end
  end

  defp project_payload(project) do
    payload = Map.get(project, :payload, Map.get(project, "payload", %{}))

    if is_map(payload) do
      {:ok, :erlang.term_to_binary(payload, compressed: 6)}
    else
      {:error, :invalid_project_payload}
    end
  end

  defp project_statuses(opts) do
    statuses =
      (opts[:status] || @project_statuses)
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    if statuses != [] and Enum.all?(statuses, &(&1 in @project_statuses)) do
      {:ok, statuses}
    else
      {:error, :invalid_status}
    end
  end

  defp project_limit(opts) do
    case Keyword.get(opts, :limit, 50) do
      limit when is_integer(limit) and limit in 1..500 -> {:ok, limit}
      _ -> {:error, :invalid_limit}
    end
  end

  defp project_filters(opts, statuses) do
    {clauses, params} =
      [{:session_id, "session_id"}, {:kind, "kind"}]
      |> Enum.reduce({[], []}, fn {key, column}, {clauses, params} ->
        case Keyword.get(opts, key) do
          value when is_binary(value) and value != "" ->
            {clauses ++ ["#{column} = ?#{length(params) + 1}"], params ++ [value]}

          _ ->
            {clauses, params}
        end
      end)

    {status_placeholders, params} = status_placeholders(statuses, params)
    clauses = clauses ++ ["status IN (#{status_placeholders})"]

    where = "WHERE " <> Enum.join(clauses, " AND ")
    {where, params}
  end

  defp status_placeholders(statuses, params) do
    {placeholders, params} =
      Enum.map_reduce(statuses, params, fn status, acc ->
        index = length(acc) + 1
        {"?#{index}", acc ++ [status]}
      end)

    {Enum.join(placeholders, ", "), params}
  end

  defp project_from_row([id, session_id, kind, status, payload, inserted_at, updated_at]) do
    with {:ok, decoded} <- decode_project_payload(payload) do
      {:ok,
       %{
         id: id,
         session_id: session_id,
         kind: kind,
         status: project_status_atom(status),
         payload: decoded,
         inserted_at: parse_timestamp(inserted_at),
         updated_at: parse_timestamp(updated_at)
       }}
    end
  end

  defp decode_project_payload(payload) when is_binary(payload) do
    try do
      {:ok, :erlang.binary_to_term(payload, [:safe])}
    rescue
      _ -> {:error, :invalid_project_payload}
    end
  end

  defp decode_project_payload(_payload), do: {:error, :invalid_project_payload}

  defp project_status_atom(status) do
    case status do
      "planning" -> :planning
      "awaiting_approval" -> :awaiting_approval
      "running" -> :running
      "paused" -> :paused
      "error" -> :error
      "completed" -> :completed
      "stopped" -> :stopped
      _ -> :unknown
    end
  end

  # --- Pairing State ---

  @impl true
  @spec upsert_pairing_state(term(), String.t(), String.t() | nil, map()) ::
          :ok | {:error, term()}
  def upsert_pairing_state(channel, sender_id, agent_id, raw_data \\ %{}) do
    now = now_iso8601()

    SQLite.execute(
      SQLite.default_server(),
      """
      INSERT INTO pairing_states (channel, sender_id, agent_id, paired_at, raw_data)
      VALUES (?1, ?2, ?3, ?4, ?5)
      ON CONFLICT(channel, sender_id) DO UPDATE SET
        agent_id = excluded.agent_id,
        paired_at = excluded.paired_at,
        raw_data = excluded.raw_data
      """,
      [to_string(channel), to_string(sender_id), agent_id, now, Jason.encode!(raw_data || %{})]
    )
  end

  @impl true
  @spec get_pairing_state(term(), String.t()) :: map() | nil
  def get_pairing_state(channel, sender_id) do
    case SQLite.query(
           SQLite.default_server(),
           """
           SELECT channel, sender_id, agent_id, paired_at, raw_data
           FROM pairing_states
           WHERE channel = ?1 AND sender_id = ?2
           LIMIT 1
           """,
           [to_string(channel), to_string(sender_id)]
         ) do
      {:ok, %{rows: [[ch, sid, aid, paired_at, raw_json]]}} ->
        %{
          channel: ch,
          sender_id: sid,
          agent_id: aid,
          paired_at: parse_timestamp(paired_at),
          raw_data: decode_json(raw_json)
        }

      _ ->
        nil
    end
  end

  @impl true
  @spec delete_pairing_state(term(), String.t()) :: :ok | {:error, term()}
  def delete_pairing_state(channel, sender_id) do
    SQLite.execute(
      SQLite.default_server(),
      "DELETE FROM pairing_states WHERE channel = ?1 AND sender_id = ?2",
      [to_string(channel), to_string(sender_id)]
    )
  end

  @impl true
  @spec list_pairing_states_by_channel(term()) :: [map()]
  def list_pairing_states_by_channel(channel) do
    case SQLite.query(
           SQLite.default_server(),
           """
           SELECT channel, sender_id, agent_id, paired_at, raw_data
           FROM pairing_states
           WHERE channel = ?1
           """,
           [to_string(channel)]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [ch, sid, aid, paired_at, raw_json] ->
          %{
            channel: ch,
            sender_id: sid,
            agent_id: aid,
            paired_at: parse_timestamp(paired_at),
            raw_data: decode_json(raw_json)
          }
        end)

      _ ->
        []
    end
  end

  # --- Private Node / Edge Helpers ---

  defp ensure_node(target, type, data) do
    case find_node_by_path(target, type, data["path"], data["workspace_root"]) do
      nil -> create_node(target, type, data)
      node -> {:ok, node}
    end
  end

  defp find_node_by_path(target, type, path, workspace_root) do
    {sql, params} =
      if workspace_root do
        {
          """
          SELECT id, type, data, access_count, inserted_at
          FROM nodes
          WHERE type = ?1
            AND json_extract(data, '$.path') = ?2
            AND json_extract(data, '$.workspace_root') = ?3
          LIMIT 1
          """,
          [type, path, workspace_root]
        }
      else
        {
          """
          SELECT id, type, data, access_count, inserted_at
          FROM nodes
          WHERE type = ?1
            AND json_extract(data, '$.path') = ?2
          LIMIT 1
          """,
          [type, path]
        }
      end

    case SQLite.query(target, sql, params) do
      {:ok, %{rows: [[id, t, json, ac, ins]]}} ->
        %{id: id, type: t, data: decode_json(json), access_count: ac || 0, inserted_at: ins}

      _ ->
        nil
    end
  end

  defp find_node_by_pattern_key(target, pattern_key) do
    case SQLite.query(
           target,
           """
           SELECT id, type, data, access_count, inserted_at
           FROM nodes
           WHERE json_extract(data, '$.pattern_key') = ?1
           LIMIT 1
           """,
           [pattern_key]
         ) do
      {:ok, %{rows: [[id, t, json, ac, ins]]}} ->
        %{id: id, type: t, data: decode_json(json), access_count: ac || 0, inserted_at: ins}

      _ ->
        nil
    end
  end

  defp find_node_by_name(target, type, name) do
    case SQLite.query(
           target,
           """
           SELECT id, type, data, access_count, inserted_at
           FROM nodes
           WHERE type = ?1
             AND LOWER(COALESCE(json_extract(data, '$.name'), '')) = LOWER(?2)
           LIMIT 1
           """,
           [type, name]
         ) do
      {:ok, %{rows: [[id, t, json, ac, ins]]}} ->
        %{id: id, type: t, data: decode_json(json), access_count: ac || 0, inserted_at: ins}

      _ ->
        nil
    end
  end

  defp find_or_create_entity(target, type, name, data) do
    case find_node_by_name(target, type, name) do
      nil -> create_node(target, type, data)
      node -> {:ok, node}
    end
  end

  defp sync_vec_node(target, node_id, vector) do
    if SQLite.vec_enabled?(target) do
      with {:ok, %{rows: [[rowid]]}} <-
             SQLite.query(target, "SELECT rowid FROM nodes WHERE id = ?1", [node_id]),
           :ok <- SQLite.execute(target, "DELETE FROM vec_nodes WHERE rowid = ?1", [rowid]) do
        maybe_insert_vec_node(target, rowid, vector)
      else
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp maybe_insert_vec_node(_target, _rowid, vector) when not is_list(vector) or vector == [] do
    :ok
  end

  defp maybe_insert_vec_node(target, rowid, vector) do
    if valid_vector?(vector) do
      case SQLite.execute(
             target,
             "INSERT INTO vec_nodes(rowid, embedding) VALUES (?1, ?2)",
             [rowid, Jason.encode!(vector)]
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("[SQLITE] vec0 insert skipped: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp valid_vector?(vector) when is_list(vector) and vector != [] do
    Enum.all?(vector, &is_number/1)
  end

  defp valid_vector?(_vector), do: false

  defp create_node(target, type, data, embedding_json \\ nil) do
    id = SQLite.uuid()
    now = now_iso8601()

    case SQLite.execute(
           target,
           """
           INSERT INTO nodes (id, type, data, embedding, access_count, inserted_at, updated_at)
           VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6)
           """,
           [id, type, Jason.encode!(data), embedding_json, now, now]
         ) do
      :ok -> {:ok, %{id: id, type: type, data: data, access_count: 0, inserted_at: now}}
      error -> error
    end
  end

  defp update_node_data(target, id, next_data) do
    now = now_iso8601()

    case SQLite.execute(
           target,
           "UPDATE nodes SET data = ?1, updated_at = ?2 WHERE id = ?3",
           [Jason.encode!(next_data), now, id]
         ) do
      :ok -> {:ok, %{id: id, data: next_data}}
      error -> error
    end
  end

  defp create_edge(target, from_id, to_id, type) do
    SQLite.execute(
      target,
      "INSERT INTO edges (id, from_id, to_id, type, inserted_at) VALUES (?1, ?2, ?3, ?4, ?5)",
      [SQLite.uuid(), from_id, to_id, type, now_iso8601()]
    )
  end

  defp find_edge(target, from_id, to_id, type) do
    case SQLite.query(
           target,
           "SELECT id FROM edges WHERE from_id = ?1 AND to_id = ?2 AND type = ?3 LIMIT 1",
           [from_id, to_id, type]
         ) do
      {:ok, %{rows: [[id]]}} -> id
      _ -> nil
    end
  end

  defp find_connected_node(target, from_id, edge_type, target_type) do
    case SQLite.query(
           target,
           """
           SELECT n.id, n.data
           FROM nodes AS n
           JOIN edges AS e ON e.to_id = n.id
           WHERE e.from_id = ?1 AND e.type = ?2 AND n.type = ?3
           LIMIT 1
           """,
           [from_id, edge_type, target_type]
         ) do
      {:ok, %{rows: [[id, json]]}} -> %{id: id, data: decode_json(json)}
      _ -> nil
    end
  end

  defp find_connected_rev_node(target, to_id, edge_type, source_type) do
    case SQLite.query(
           target,
           """
           SELECT n.id, n.data
           FROM nodes AS n
           JOIN edges AS e ON e.from_id = n.id
           WHERE e.to_id = ?1 AND e.type = ?2 AND n.type = ?3
           LIMIT 1
           """,
           [to_id, edge_type, source_type]
         ) do
      {:ok, %{rows: [[id, json]]}} -> %{id: id, data: decode_json(json)}
      _ -> nil
    end
  end

  defp upsert_document_fts(tx, node_id, content, path) do
    with :ok <- SQLite.execute(tx, "DELETE FROM documents_fts WHERE node_id = ?1", [node_id]) do
      SQLite.execute(
        tx,
        "INSERT INTO documents_fts (node_id, content, path) VALUES (?1, ?2, ?3)",
        [node_id, to_string(content || ""), to_string(path || "")]
      )
    end
  end

  # --- FTS5 & Fallback Search ---

  defp search_messages_fts(query, limit) do
    case to_fts_match(query) do
      nil ->
        {:ok, []}

      fts_query ->
        case SQLite.query(
               SQLite.default_server(),
               """
               SELECT m.id, m.session_id, m.role, m.content, -bm25(messages_fts) AS score
               FROM messages AS m
               JOIN messages_fts ON messages_fts.rowid = m.id
               WHERE messages_fts MATCH ?1
               ORDER BY score DESC, m.id DESC
               LIMIT ?2
               """,
               [fts_query, limit]
             ) do
          {:ok, %{rows: rows}} ->
            {:ok,
             Enum.map(rows, fn [id, sid, role, content, score] ->
               %{
                 kind: :message,
                 role: role,
                 content: content,
                 source: "session:#{sid}:message:#{id}",
                 citation: "session #{sid} / #{role} / message ##{id}",
                 score: normalize_bm25(score)
               }
             end)}

          error ->
            error
        end
    end
  end

  defp fallback_search_messages(query, limit) do
    tokens = search_tokens(query)
    server = SQLite.default_server()

    if tokens == [] do
      {:ok, []}
    else
      case SQLite.query(
             server,
             "SELECT id, session_id, role, content FROM messages ORDER BY id DESC"
           ) do
        {:ok, %{rows: rows}} ->
          hits =
            rows
            |> Enum.filter(fn [_id, _sid, _role, content] ->
              haystack = String.downcase(content || "")
              Enum.all?(tokens, &String.contains?(haystack, &1))
            end)
            |> Enum.take(limit)
            |> Enum.map(fn [id, sid, role, content] ->
              %{
                kind: :message,
                role: role,
                content: content,
                source: "session:#{sid}:message:#{id}",
                citation: "session #{sid} / #{role} / message ##{id}",
                score: 0.5
              }
            end)

          {:ok, hits}

        error ->
          error
      end
    end
  end

  defp search_documents_fts(query, limit, opts) do
    case to_fts_match(query) do
      nil ->
        {:ok, []}

      fts_query ->
        server = SQLite.default_server()
        query_tokens = search_tokens(query)
        include_forgotten? = Keyword.get(opts, :include_forgotten, false)

        case SQLite.query(
               server,
               """
               SELECT n.id, n.data, n.access_count, n.inserted_at, -bm25(documents_fts) AS score
               FROM documents_fts AS f
               JOIN nodes AS n ON n.id = f.node_id
               WHERE documents_fts MATCH ?1 AND n.type = 'document'
               ORDER BY score DESC
               LIMIT ?2
               """,
               [fts_query, limit * 4]
             ) do
          {:ok, %{rows: rows}} ->
            results =
              rows
              |> Enum.map(fn [id, json, ac, ins, raw_score] ->
                node = %{
                  id: id,
                  data: decode_json(json),
                  access_count: ac || 0,
                  inserted_at: ins
                }

                {node, raw_score}
              end)
              |> Enum.filter(fn {node, _score} ->
                document_matches_opts?(node.data, opts) and
                  match_workspace?(node.data, opts) and
                  (include_forgotten? or not memory_forgotten?(node.data))
              end)
              |> Enum.take(limit)
              |> Enum.map(fn {node, raw_score} ->
                scoring =
                  score_document(server, node, :text, normalize_bm25(raw_score), query_tokens)

                touch_memory_access(server, node)
                {node, scoring}
              end)
              |> Enum.sort_by(
                fn {node, scoring} -> {scoring.score, node.inserted_at} end,
                :desc
              )
              |> Enum.map(fn {node, scoring} -> document_result(node, scoring) end)

            {:ok, results}

          error ->
            error
        end
    end
  end

  defp fallback_search_documents(query, limit, opts) do
    tokens = search_tokens(query)
    server = SQLite.default_server()
    include_forgotten? = Keyword.get(opts, :include_forgotten, false)

    if tokens == [] do
      {:ok, []}
    else
      case SQLite.query(
             server,
             "SELECT id, data, access_count, inserted_at FROM nodes WHERE type = 'document' ORDER BY inserted_at DESC"
           ) do
        {:ok, %{rows: rows}} ->
          results =
            rows
            |> Enum.map(fn [id, json, ac, ins] ->
              %{id: id, data: decode_json(json), access_count: ac || 0, inserted_at: ins}
            end)
            |> Enum.filter(fn node ->
              haystack = String.downcase(node.data["content"] || "")

              Enum.all?(tokens, &String.contains?(haystack, &1)) and
                document_matches_opts?(node.data, opts) and
                match_workspace?(node.data, opts) and
                (include_forgotten? or not memory_forgotten?(node.data))
            end)
            |> Enum.map(fn node ->
              haystack = String.downcase(node.data["content"] || "")

              signal_score =
                tokens
                |> Enum.count(&String.contains?(haystack, &1))
                |> Kernel./(max(length(tokens), 1))

              scoring = score_document(server, node, :text, signal_score, tokens)
              touch_memory_access(server, node)
              document_result(node, scoring)
            end)
            |> Enum.sort_by(& &1.score, :desc)
            |> Enum.take(limit)

          {:ok, results}

        error ->
          error
      end
    end
  end

  defp search_bug_fix_nodes(server, tokens, limit) do
    case SQLite.query(
           server,
           """
           SELECT COALESCE(json_extract(b.data, '$.description'), ''),
                  COALESCE(json_extract(fx.data, '$.summary'), ''),
                  COALESCE(json_extract(f.data, '$.path'), '')
           FROM nodes AS b
           JOIN edges AS occ ON occ.from_id = b.id AND occ.type = 'occurs_in'
           JOIN nodes AS f ON f.id = occ.to_id AND f.type = 'file'
           LEFT JOIN edges AS sol ON sol.to_id = b.id AND sol.type = 'solves'
           LEFT JOIN nodes AS fx ON fx.id = sol.from_id AND fx.type = 'fix'
           WHERE b.type = 'bug'
           LIMIT ?1
           """,
           [limit * 3]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [bug, fix, file] ->
          graph_history_result(%{bug: bug, fix: fix, file: file}, tokens)
        end)

      _ ->
        []
    end
  end

  defp search_knowledge_nodes(server, tokens, limit) do
    case SQLite.query(
           server,
           """
           SELECT id, type, data
           FROM nodes
           WHERE type IN ('decision', 'pattern', 'person', 'animal')
           LIMIT ?1
           """,
           [limit * 4]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id, type, json] ->
          knowledge_node_result(%{id: id, type: type, data: decode_json(json)}, tokens)
        end)

      _ ->
        []
    end
  end

  # --- Scoring & Cosine Similarity ---

  defp cosine_similarity(a, b)
       when is_list(a) and is_list(b) and length(a) == length(b) and a != [] do
    {dot, norm_a, norm_b} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {d, na, nb} ->
        xf = x * 1.0
        yf = y * 1.0
        {d + xf * yf, na + xf * xf, nb + yf * yf}
      end)

    denom = :math.sqrt(norm_a) * :math.sqrt(norm_b)
    if denom == 0.0, do: 0.0, else: clamp_score(dot / denom)
  end

  defp cosine_similarity(_a, _b), do: 0.0

  defp score_document(server, node, signal, raw_signal_score, query_tokens) do
    signal_score = clamp_score(raw_signal_score)
    metadata = metadata_boosts(server, node, query_tokens)

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

  defp metadata_boosts(server, node, query_tokens) do
    importance = min(0.35, (node.data["importance"] || 5) / 10 * 0.35)

    access =
      node.data["access_count"]
      |> Kernel.||(0)
      |> Kernel.+(1)
      |> :math.log10()
      |> Kernel.*(0.12)
      |> min(0.18)

    freshness = freshness_boost(node)
    graph = graph_boost(server, node, query_tokens)
    total = importance + access + freshness + graph

    %{
      total: total,
      components: %{importance: importance, access: access, freshness: freshness, graph: graph}
    }
  end

  defp freshness_boost(node) do
    timestamp =
      parse_timestamp(node.data["last_accessed_at"]) || parse_timestamp(node.inserted_at)

    case timestamp do
      nil ->
        0.0

      datetime ->
        age_days = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0) / 86_400
        0.18 * :math.exp(-age_days / 30)
    end
  end

  defp graph_boost(server, node, query_tokens) do
    path = node.data["path"]

    if is_binary(path) do
      case find_node_by_path(server, "file", path, nil) do
        nil ->
          0.0

        file_node ->
          {bugs, fixes, overlap} = graph_signal_for_file(server, file_node.id, query_tokens)

          incident_bonus =
            if incident_query?(query_tokens) and (bugs > 0 or fixes > 0), do: 0.05, else: 0.0

          overlap_bonus = min(0.08, overlap * 0.04)

          if bugs > 0 or fixes > 0 do
            min(
              0.45,
              0.18 + min(0.12, bugs * 0.10) + min(0.15, fixes * 0.15) + incident_bonus +
                overlap_bonus
            )
          else
            0.0
          end
      end
    else
      0.0
    end
  end

  defp graph_signal_for_file(server, file_id, query_tokens) do
    with {:ok, %{rows: bug_rows}} <-
           SQLite.query(
             server,
             """
             SELECT b.id, COALESCE(json_extract(b.data, '$.description'), '')
             FROM nodes AS b
             JOIN edges AS e ON e.from_id = b.id
             WHERE e.to_id = ?1 AND e.type = 'occurs_in' AND b.type = 'bug'
             """,
             [file_id]
           ) do
      bug_texts = Enum.map(bug_rows, fn [_id, desc] -> desc end)
      bug_ids = Enum.map(bug_rows, fn [id, _desc] -> id end)

      fix_texts =
        if bug_ids == [] do
          []
        else
          placeholders =
            Enum.with_index(bug_ids, 1) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

          case SQLite.query(
                 server,
                 """
                 SELECT COALESCE(json_extract(fx.data, '$.summary'), '')
                 FROM nodes AS fx
                 JOIN edges AS e ON e.from_id = fx.id
                 WHERE e.to_id IN (#{placeholders}) AND e.type = 'solves' AND fx.type = 'fix'
                 """,
                 bug_ids
               ) do
            {:ok, %{rows: fx_rows}} -> Enum.map(fx_rows, &hd/1)
            _ -> []
          end
        end

      text = Enum.join(bug_texts ++ fix_texts, " ") |> String.downcase()
      overlap = Enum.count(query_tokens, &String.contains?(text, &1))
      {length(bug_ids), length(fix_texts), overlap}
    else
      _ -> {0, 0, 0}
    end
  end

  defp touch_memory_access(server, node) do
    now = now_iso8601()

    next_data =
      node.data
      |> Map.put("access_count", (node.data["access_count"] || 0) + 1)
      |> Map.put("last_accessed_at", now)

    _ =
      SQLite.execute(
        server,
        """
        UPDATE nodes
        SET data = ?1, access_count = ?2, last_accessed_at = ?3, updated_at = ?4
        WHERE id = ?5
        """,
        [Jason.encode!(next_data), (node.access_count || 0) + 1, now, now, node.id]
      )

    :ok
  end

  defp document_result(node, scoring), do: MemoryHelpers.document_result(node, scoring)

  defp knowledge_node_result(%{type: "decision", id: id, data: data}, tokens) do
    topic = data["topic"] || ""
    rationale = data["rationale"] || ""
    score = token_overlap_score("#{topic} #{rationale}", tokens)

    %{
      kind: :graph,
      content: "Decision: #{topic}. Rationale: #{rationale}",
      source: "graph://decision/#{id}",
      citation: "decision",
      score: score
    }
  end

  defp knowledge_node_result(%{type: "pattern", id: id, data: data}, tokens) do
    name = data["name"] || ""
    description = data["description"] || ""
    score = token_overlap_score("#{name} #{description}", tokens)

    %{
      kind: :graph,
      content: "Pattern: #{name}. #{description}",
      source: "graph://pattern/#{id}",
      citation: "pattern",
      score: score
    }
  end

  defp knowledge_node_result(%{type: "person", data: data}, tokens) do
    name = data["name"] || ""
    role = data["role"] || ""
    notes = data["notes"] || ""
    score = token_overlap_score("#{name} #{role} #{notes}", tokens)
    description = [role, notes] |> Enum.reject(&(&1 == "")) |> Enum.join(". ")
    content = if description == "", do: "Person: #{name}", else: "Person: #{name}. #{description}"

    %{
      kind: :graph,
      content: content,
      source: "graph://person/#{name}",
      citation: "person",
      score: score
    }
  end

  defp knowledge_node_result(%{type: "animal", data: data}, tokens) do
    name = data["name"] || ""
    species = data["species"] || ""
    notes = data["notes"] || ""
    score = token_overlap_score("#{name} #{species} #{notes}", tokens)
    description = [species, notes] |> Enum.reject(&(&1 == "")) |> Enum.join(", ")

    content =
      if description == "", do: "Animal: #{name}", else: "Animal: #{name} (#{description})"

    %{
      kind: :graph,
      content: content,
      source: "graph://animal/#{name}",
      citation: "animal",
      score: score
    }
  end

  defp knowledge_node_result(_, _tokens), do: %{kind: :graph, content: "", score: 0.0}

  defp graph_history_result(%{bug: bug, fix: fix, file: file}, query_tokens) do
    normalized = token_overlap_score("#{bug} #{fix} #{file}", query_tokens)
    incident_bonus = if incident_query?(query_tokens), do: 0.1, else: 0.0

    %{
      kind: :graph,
      bug: bug,
      fix: fix,
      file: file,
      content: "Bug: #{bug}. Fix: #{fix}. File: #{file}",
      source: "graph://#{file}",
      citation: "graph #{file}",
      score: min(1.0, normalized + incident_bonus)
    }
  end

  # --- Utility Helpers ---

  defp to_fts_match(query) do
    case search_tokens(query) do
      [] -> nil
      tokens -> Enum.map_join(tokens, " ", &"\"#{&1}\"")
    end
  end

  defp search_tokens(query), do: MemoryHelpers.search_tokens(query)

  defp token_overlap_score(text, tokens) do
    downcased = String.downcase(text)
    overlap = Enum.count(tokens, &String.contains?(downcased, &1))
    overlap / max(length(tokens), 1)
  end

  defp normalize_bm25(score) when is_number(score), do: clamp_score(score / (score + 1.0))
  defp normalize_bm25(_), do: 0.5

  defp clamp_score(score), do: MemoryHelpers.clamp_score(score)

  defp build_memory_metadata(path, content, memory_type, opts),
    do: MemoryHelpers.build_memory_metadata(path, content, memory_type, opts)

  defp document_matches_opts?(data, opts), do: MemoryHelpers.document_matches_opts?(data, opts)
  defp match_workspace?(data, opts), do: MemoryHelpers.match_workspace?(data, opts)
  defp memory_forgotten?(data), do: MemoryHelpers.memory_forgotten?(data)
  defp incident_query?(tokens), do: MemoryHelpers.incident_query?(tokens)
  defp build_citation(data), do: MemoryHelpers.build_citation(data)
  defp extract_session_id(value), do: MemoryHelpers.extract_session_id(value)

  defp build_structured_id(prefix, content),
    do: MemoryHelpers.build_structured_id(prefix, content)

  defp build_pattern_key(category, summary),
    do: MemoryHelpers.build_pattern_key(category, summary)

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp parse_timestamp(value), do: SQLite.parse_datetime(value)

  defp decode_json(json) do
    case SQLite.decode_json(json, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_embedding(json) do
    case SQLite.decode_json(json, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp maybe_put(map, key, value), do: MemoryHelpers.maybe_put(map, key, value)
  defp stringify_keys(map), do: MemoryHelpers.stringify_keys(map)
end
