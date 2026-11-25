defmodule Pincer.Infra.SQLiteTest do
  use ExUnit.Case, async: false

  alias Pincer.Infra.SQLite

  describe "initialization and pragmas" do
    test "enables WAL mode, busy_timeout, and foreign_keys on file-backed DB and initializes idempotently" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "pincer_sqlite_#{System.unique_integer([:positive])}")

      db_path = Path.join(tmp_dir, "nested/pincer.db")
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      name = :"sqlite_file_#{System.unique_integer([:positive])}"
      pid = start_supervised!({SQLite, name: name, db_path: db_path})

      assert {:ok, %{rows: [["wal"]]}} = SQLite.query(pid, "PRAGMA journal_mode;")
      assert {:ok, %{rows: [[1]]}} = SQLite.query(pid, "PRAGMA foreign_keys;")
      assert {:ok, %{rows: [[timeout]]}} = SQLite.query(pid, "PRAGMA busy_timeout;")
      assert timeout >= 5_000

      assert {:ok, %{rows: table_rows}} =
               SQLite.query(
                 pid,
                 "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name;"
               )

      tables = List.flatten(table_rows)

      for expected <- [
            "messages",
            "messages_fts",
            "nodes",
            "edges",
            "documents_fts",
            "checkpoints",
            "pairing_states",
            "self_states",
            "lessons",
            "cron_jobs",
            "audit_log",
            "dead_letter_queue"
          ] do
        assert expected in tables, "Missing table #{expected} in #{inspect(tables)}"
      end

      # Stop and reopen same file cleanly (idempotent DDL)
      stop_supervised!(SQLite)
      name2 = :"sqlite_file_reopen_#{System.unique_integer([:positive])}"
      pid2 = start_supervised!({SQLite, name: name2, db_path: db_path}, id: :reopen)
      assert {:ok, %{rows: [["wal"]]}} = SQLite.query(pid2, "PRAGMA journal_mode;")
    end
  end

  describe "query/3, execute/3, transaction/2, and FTS5 triggers" do
    setup do
      pid = start_supervised!({SQLite, name: nil, db_path: ":memory:"})
      {:ok, db: pid}
    end

    test "executes inserts, syncs messages_fts via triggers, and deletes cleanly", %{db: db} do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      assert :ok =
               SQLite.execute(
                 db,
                 "INSERT INTO messages (session_id, role, content, inserted_at) VALUES (?1, ?2, ?3, ?4)",
                 ["sess-1", "user", "elixir otp genserver supervision tree", now]
               )

      assert {:ok, %{columns: ["id", "session_id", "content"], rows: [[id, "sess-1", _]]}} =
               SQLite.query(
                 db,
                 """
                 SELECT m.id, m.session_id, m.content
                 FROM messages AS m
                 JOIN messages_fts ON messages_fts.rowid = m.id
                 WHERE messages_fts MATCH ?1
                 """,
                 ["genserver"]
               )

      assert :ok = SQLite.execute(db, "DELETE FROM messages WHERE id = ?1", [id])

      assert {:ok, %{rows: []}} =
               SQLite.query(
                 db,
                 "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?1",
                 ["genserver"]
               )
    end

    test "transaction commits on {:ok, value} and rolls back on {:error, reason} or raise", %{
      db: db
    } do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      assert {:ok, :committed} =
               SQLite.transaction(db, fn tx ->
                 :ok =
                   SQLite.execute(
                     tx,
                     "INSERT INTO messages (session_id, role, content, inserted_at) VALUES (?1, ?2, ?3, ?4)",
                     ["tx-sess", "user", "first commit", now]
                   )

                 {:ok, :committed}
               end)

      assert {:error, :abort_tx} =
               SQLite.transaction(db, fn tx ->
                 :ok =
                   SQLite.execute(
                     tx,
                     "INSERT INTO messages (session_id, role, content, inserted_at) VALUES (?1, ?2, ?3, ?4)",
                     ["tx-sess", "user", "rolled back error", now]
                   )

                 {:error, :abort_tx}
               end)

      assert {:error, {:exception, %RuntimeError{message: "boom"}}} =
               SQLite.transaction(db, fn tx ->
                 :ok =
                   SQLite.execute(
                     tx,
                     "INSERT INTO messages (session_id, role, content, inserted_at) VALUES (?1, ?2, ?3, ?4)",
                     ["tx-sess", "user", "rolled back crash", now]
                   )

                 raise "boom"
               end)

      assert {:ok, %{rows: [["first commit"]]}} =
               SQLite.query(db, "SELECT content FROM messages WHERE session_id = ?1", ["tx-sess"])
    end

    test "normalizes query and Exqlite transaction errors into {:db_error, reason}", %{db: db} do
      assert {:error, {:db_error, message}} =
               SQLite.query(db, "SELECT * FROM nonexistent_table")

      assert is_binary(message) and message =~ "no such table"

      assert {:error, {:db_error, "database is locked"}} =
               SQLite.transaction(db, fn _tx ->
                 raise Exqlite.Error, message: "database is locked"
               end)
    end
  end

  describe "decode_json/2 and parse_datetime/1" do
    test "safely decodes valid JSON and returns fallback on invalid input" do
      assert SQLite.decode_json(~s({"a":1})) == %{"a" => 1}
      assert SQLite.decode_json("[1,2]", []) == [1, 2]
      assert SQLite.decode_json("not-json", %{}) == %{}
      assert SQLite.decode_json(nil, []) == []
    end

    test "parses ISO8601 strings to DateTime and returns nil otherwise" do
      assert %DateTime{year: 2026} = SQLite.parse_datetime("2026-11-20T12:00:00Z")
      assert SQLite.parse_datetime("bad-date") == nil
      assert SQLite.parse_datetime(nil) == nil
    end
  end

  describe "health_check/0" do
    test "returns :ok confirming SQLite3 and FTS5 availability" do
      assert :ok = SQLite.health_check()
    end
  end
end
