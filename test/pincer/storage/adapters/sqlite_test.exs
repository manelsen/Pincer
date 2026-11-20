defmodule Pincer.Storage.Adapters.SQLiteTest do
  use ExUnit.Case, async: false

  alias Pincer.Infra.SQLite
  alias Pincer.Storage.Adapters.SQLite, as: SQLiteStorage
  alias Pincer.Storage.Checkpoint

  setup do
    prev_server = Application.get_env(:pincer, :sqlite_server)
    db_pid = start_supervised!({SQLite, name: nil, db_path: ":memory:"})
    Application.put_env(:pincer, :sqlite_server, db_pid)

    on_exit(fn ->
      if prev_server do
        Application.put_env(:pincer, :sqlite_server, prev_server)
      else
        Application.delete_env(:pincer, :sqlite_server)
      end
    end)

    {:ok, db: db_pid}
  end

  describe "messages & session/message FTS search" do
    test "save_message, get_messages, and delete_messages preserve ordering and isolation" do
      assert {:ok, _} = SQLiteStorage.save_message("s1", "user", "hello sqlite")
      assert {:ok, _} = SQLiteStorage.save_message("s1", "assistant", "world reply")
      assert {:ok, _} = SQLiteStorage.save_message("s2", "user", "other session")

      assert [
               %{role: "user", content: "hello sqlite"},
               %{role: "assistant", content: "world reply"}
             ] = SQLiteStorage.get_messages("s1")

      assert :ok = SQLiteStorage.delete_messages("s1")
      assert [] = SQLiteStorage.get_messages("s1")
      assert [%{role: "user", content: "other session"}] = SQLiteStorage.get_messages("s2")
    end

    test "search_messages/2 handles FTS5 matches, punctuation queries, and substring fallback" do
      {:ok, _} = SQLiteStorage.save_message("s1", "user", "timeout error in foo-bar module")
      {:ok, _} = SQLiteStorage.save_message("s2", "assistant", "unrelated greeting")

      assert {:ok, [hit]} = SQLiteStorage.search_messages("timeout module", 5)
      assert hit.kind == :message
      assert hit.content =~ "timeout"
      assert hit.source =~ "session:s1:message:"

      # Punctuation / FTS5 special operators must not raise syntax errors
      assert {:ok, [special_hit]} = SQLiteStorage.search_messages("foo-bar: (module)*", 5)
      assert special_hit.content =~ "foo-bar"
    end

    test "search_sessions/2 groups hits by session" do
      {:ok, _} = SQLiteStorage.save_message("sess-a", "user", "pgvector index tuning")
      {:ok, _} = SQLiteStorage.save_message("sess-a", "assistant", "pgvector tuning complete")
      {:ok, _} = SQLiteStorage.save_message("sess-b", "user", "pgvector backup")

      assert {:ok, sessions} = SQLiteStorage.search_sessions("pgvector", 5)
      assert length(sessions) == 2
      top = hd(sessions)
      assert top.session_id == "sess-a"
      assert top.hit_count == 2
      assert length(top.hits) == 2
    end
  end

  describe "graph knowledge & learnings" do
    test "ingest_bug_fix, query_history, and search_graph_history" do
      assert :ok =
               SQLiteStorage.ingest_bug_fix(
                 "Timeout in webhook handler",
                 "Increased pool timeout",
                 "lib/webhook.ex"
               )

      assert [
               %{
                 bug: "Timeout in webhook handler",
                 file: "lib/webhook.ex",
                 fix: "Increased pool timeout"
               }
             ] =
               SQLiteStorage.query_history()

      assert {:ok, [hit | _]} = SQLiteStorage.search_graph_history("webhook timeout", 5)
      assert hit.kind == :graph
      assert hit.file == "lib/webhook.ex"
    end

    test "ingest_decision, pattern, person, animal, and idempotent entity relation" do
      assert :ok = SQLiteStorage.ingest_decision("SQLite", "Zero-infra option", "lib/sqlite.ex")
      assert :ok = SQLiteStorage.ingest_pattern("CircuitBreaker", "Fail fast on provider outage")
      assert :ok = SQLiteStorage.ingest_person("Alice", %{role: "engineer"})
      assert :ok = SQLiteStorage.ingest_person("alice", %{notes: "case-insensitive"})
      assert :ok = SQLiteStorage.ingest_animal("Pippin", "cat", "orange")

      assert :ok =
               SQLiteStorage.ingest_entity_relation("Alice", "person", "owns", "Pippin", "animal")

      assert :ok =
               SQLiteStorage.ingest_entity_relation("Alice", "person", "owns", "Pippin", "animal")

      assert {:ok, hits} = SQLiteStorage.search_graph_history("SQLite CircuitBreaker", 5)
      assert Enum.any?(hits, &String.contains?(&1.content, "Decision: SQLite"))
    end

    test "save_learning and save_tool_error deduplicate pattern_key and list_recent_learnings returns newest" do
      assert {:ok, _} = SQLiteStorage.save_learning("testing", "Run mix qa")
      assert {:ok, _} = SQLiteStorage.save_learning("testing", "Run mix qa")
      assert {:ok, _} = SQLiteStorage.save_tool_error("safe_shell", %{"cmd" => "rm"}, "blocked")

      recent = SQLiteStorage.list_recent_learnings(5)
      assert length(recent) == 2
      assert Enum.any?(recent, &(&1.type == :learning and &1.summary == "Run mix qa"))
      assert Enum.any?(recent, &(&1.type == :error and &1.tool == "safe_shell"))
    end
  end

  describe "documents, hybrid/FTS5 search, vector cosine similarity, forget & report" do
    test "index_document, index_memory, get_document_metadata, search_documents with filters" do
      assert :ok =
               SQLiteStorage.index_document(
                 "docs/arch.md",
                 "Hexagonal architecture with sandbox ports and sqlite storage",
                 [1.0, 0.0, 0.0],
                 %{"workspace_root" => "/ws1"}
               )

      assert :ok =
               SQLiteStorage.index_memory(
                 "notes/runbook.md",
                 "Runbook for deploy and health checks",
                 "technical_fact",
                 [0.0, 1.0, 0.0],
                 workspace_root: "/ws1",
                 session_id: "sess-1",
                 importance: 8,
                 line_start: 10,
                 line_end: 20
               )

      meta = SQLiteStorage.get_document_metadata("docs/arch.md", "/ws1")
      assert meta["path"] == "docs/arch.md"

      assert {:ok, [doc]} = SQLiteStorage.search_documents("sandbox", 5)
      assert doc.source == "docs/arch.md"

      assert {:ok, [mem]} =
               SQLiteStorage.search_documents("runbook", 5,
                 memory_type: "technical_fact",
                 session_id: "sess-1",
                 workspace_root: "/ws1"
               )

      assert mem.citation == "notes/runbook.md#L10-L20"
      assert mem.memory_type == "technical_fact"
    end

    test "search_similar ranks by cosine similarity and excludes forgotten memories" do
      assert :ok =
               SQLiteStorage.index_memory(
                 "mem/a.md",
                 "Vector close match",
                 "semantic",
                 [0.9, 0.1, 0.0],
                 session_id: "s1",
                 importance: 6
               )

      assert :ok =
               SQLiteStorage.index_memory(
                 "mem/b.md",
                 "Vector orthogonal",
                 "semantic",
                 [0.0, 1.0, 0.0],
                 session_id: "s2",
                 importance: 9
               )

      assert {:ok, [first, _second]} =
               SQLiteStorage.search_similar("document", [1.0, 0.0, 0.0], 5)

      assert first.source == "mem/a.md"
      assert first.signal == :semantic

      assert :ok = SQLiteStorage.forget_memory("mem/a.md")
      assert {:error, :not_found} = SQLiteStorage.forget_memory("mem/does-not-exist.md")

      assert {:ok, remaining} = SQLiteStorage.search_similar("document", [1.0, 0.0, 0.0], 5)
      refute Enum.any?(remaining, &(&1.source == "mem/a.md"))
      assert {:ok, []} = SQLiteStorage.search_documents("Vector close match", 5)

      assert {:ok, included} =
               SQLiteStorage.search_documents("Vector close match", 5, include_forgotten: true)

      assert length(included) == 1

      assert {:ok, report} = SQLiteStorage.memory_report(5)
      assert report.total_documents == 2
      assert report.forgotten_documents == 1
      assert is_map(report.by_type)
      assert is_list(report.top_documents)
      assert is_list(report.top_sessions)
    end
  end

  describe "checkpoints & pairing state" do
    test "save_checkpoint and load_checkpoint preserve binary blobs and pause prior active checkpoints" do
      snapshot_1 = :erlang.term_to_binary([%{"role" => "user", "content" => "step 1"}])
      snapshot_2 = :erlang.term_to_binary([%{"role" => "user", "content" => "step 2"}])

      assert {:ok, _} =
               SQLiteStorage.save_checkpoint("chk-sess", %{
                 status: "running",
                 history_snapshot: snapshot_1,
                 step_count: 1,
                 metadata: %{"phase" => "init"}
               })

      assert {:ok, _} =
               SQLiteStorage.save_checkpoint("chk-sess", %{
                 status: "running",
                 history_snapshot: snapshot_2,
                 step_count: 2,
                 metadata: %{"phase" => "done"}
               })

      assert {:ok, %Checkpoint{} = loaded} = SQLiteStorage.load_checkpoint("chk-sess")
      assert loaded.status == "running"
      assert loaded.step_count == 2
      assert loaded.metadata == %{"phase" => "done"}

      assert :erlang.binary_to_term(loaded.history_snapshot) == [
               %{"role" => "user", "content" => "step 2"}
             ]

      assert {:error, :not_found} = SQLiteStorage.load_checkpoint("missing-chk")
    end

    test "pairing state upsert, get, list, and delete" do
      assert :ok =
               SQLiteStorage.upsert_pairing_state(:telegram, "user-1", "agent-a", %{
                 "code" => "1234"
               })

      assert :ok =
               SQLiteStorage.upsert_pairing_state("telegram", "user-1", "agent-b", %{
                 "code" => "5678"
               })

      state = SQLiteStorage.get_pairing_state(:telegram, "user-1")
      assert state.agent_id == "agent-b"
      assert state.raw_data == %{"code" => "5678"}

      assert [%{sender_id: "user-1"}] = SQLiteStorage.list_pairing_states_by_channel(:telegram)
      assert :ok = SQLiteStorage.delete_pairing_state("telegram", "user-1")
      assert SQLiteStorage.get_pairing_state("telegram", "user-1") == nil
    end
  end

  describe "purge_invalid_documents/1" do
    test "deletes matching document nodes and documents_fts rows atomically while keeping valid entries",
         %{db: db} do
      assert :ok =
               SQLiteStorage.index_document(
                 "tmp/scratch_alpha.md",
                 "Temporary secret token alpha",
                 [0.1, 0.2]
               )

      assert :ok =
               SQLiteStorage.index_document(
                 "workspaces/agent_1/notes.md",
                 "Workspace ephemeral secret beta",
                 [0.1, 0.2]
               )

      assert :ok =
               SQLiteStorage.index_document(
                 "lib/pincer/app.ex",
                 "Production architecture reference",
                 [0.1, 0.2]
               )

      assert :ok =
               SQLiteStorage.index_document(
                 "tmp_valid_not_dir/readme.md",
                 "Literal underscore percent guard",
                 [0.1, 0.2]
               )

      assert :ok = SQLiteStorage.ingest_bug_fix("Bug", "Fix", "tmp/source_file.ex")

      assert {:ok, []} ==
               SQLiteStorage.purge_invalid_documents([]) |> then(fn {:ok, 0} -> {:ok, []} end)

      assert {:ok, 2} = SQLiteStorage.purge_invalid_documents(["tmp/", "workspaces/"])

      assert {:ok, []} = SQLiteStorage.search_documents("alpha", 5)
      assert {:ok, []} = SQLiteStorage.search_documents("beta", 5)
      assert {:ok, [valid_hit]} = SQLiteStorage.search_documents("architecture", 5)
      assert valid_hit.source == "lib/pincer/app.ex"
      assert {:ok, [underscore_hit]} = SQLiteStorage.search_documents("underscore", 5)
      assert underscore_hit.source == "tmp_valid_not_dir/readme.md"

      # Ensure documents_fts virtual table has no orphan entries for purged paths
      assert {:ok, %{rows: [[0]]}} =
               SQLite.query(
                 db,
                 "SELECT COUNT(*) FROM documents_fts WHERE path LIKE 'tmp/%' OR path LIKE 'workspaces/%'"
               )

      assert {:ok, %{rows: [[2]]}} = SQLite.query(db, "SELECT COUNT(*) FROM documents_fts")

      # Non-document graph nodes pointing to tmp/ must remain intact
      assert [%{file: "tmp/source_file.ex"}] = SQLiteStorage.query_history()
    end

    test "escapes LIKE wildcards % and _ in prefixes" do
      assert :ok =
               SQLiteStorage.index_document("100%_real/keep.md", "Keep underscore percent", [])

      assert :ok = SQLiteStorage.index_document("100abc/drop.md", "Should not match escaped", [])

      assert {:ok, 1} = SQLiteStorage.purge_invalid_documents(["100%_real/"])
      assert {:ok, []} = SQLiteStorage.search_documents("underscore", 5)
      assert {:ok, [kept]} = SQLiteStorage.search_documents("escaped", 5)
      assert kept.source == "100abc/drop.md"
    end
  end
end
