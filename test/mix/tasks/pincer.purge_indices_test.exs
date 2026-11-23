defmodule Mix.Tasks.Pincer.PurgeIndicesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pincer.PurgeIndices
  alias Pincer.Infra.SQLite
  alias Pincer.Storage.Adapters.SQLite, as: SQLiteStorage

  setup do
    prev_server = Application.get_env(:pincer, :sqlite_server)
    prev_storage = Application.get_env(:pincer, :storage_adapter)
    db_pid = start_supervised!({SQLite, name: nil, db_path: ":memory:", vec: false})
    Application.put_env(:pincer, :sqlite_server, db_pid)
    Application.put_env(:pincer, :storage_adapter, SQLiteStorage)

    on_exit(fn ->
      restore_env(:sqlite_server, prev_server)
      restore_env(:storage_adapter, prev_storage)
    end)

    {:ok, db: db_pid}
  end

  defp restore_env(key, nil), do: Application.delete_env(:pincer, key)
  defp restore_env(key, value), do: Application.put_env(:pincer, key, value)

  defp insert_node!(db, type, data) do
    id = SQLite.uuid()
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    :ok =
      SQLite.execute(
        db,
        """
        INSERT INTO nodes (id, type, data, access_count, inserted_at, updated_at)
        VALUES (?1, ?2, ?3, 0, ?4, ?4)
        """,
        [id, type, Jason.encode!(data), now]
      )

    id
  end

  defp node_ids(db) do
    {:ok, %{rows: rows}} = SQLite.query(db, "SELECT id FROM nodes")
    rows |> List.flatten() |> MapSet.new()
  end

  test "purge/2 deletes matching document nodes under tmp/ and workspaces/ on SQLite adapter",
       %{db: db} do
    assert :ok = SQLiteStorage.index_document("tmp/scratch.md", "scratch", [])

    assert :ok =
             SQLiteStorage.index_document("workspaces/agent_1/notes.md", "workspace notes", [])

    assert :ok = SQLiteStorage.index_document("tmpX/not_matching.md", "not matching", [])
    assert :ok = SQLiteStorage.index_document("lib/pincer/app.ex", "app", [])

    tmp_file_id = insert_node!(db, "file", %{"path" => "tmp/file_node.ex"})
    no_path_id = insert_node!(db, "document", %{"title" => "untitled"})

    assert {:ok, 2} = PurgeIndices.purge(SQLiteStorage)

    remaining_ids = node_ids(db)
    assert MapSet.member?(remaining_ids, tmp_file_id)
    assert MapSet.member?(remaining_ids, no_path_id)

    assert {:ok, paths} =
             SQLite.query(db, "SELECT json_extract(data, '$.path') FROM nodes ORDER BY 1")

    remaining_paths = paths.rows |> List.flatten() |> Enum.reject(&is_nil/1)

    assert "tmpX/not_matching.md" in remaining_paths
    assert "lib/pincer/app.ex" in remaining_paths
    refute "tmp/scratch.md" in remaining_paths
    refute "workspaces/agent_1/notes.md" in remaining_paths
  end

  test "purge/2 handles wildcard escapes and empty prefix list on SQLite adapter", %{db: db} do
    assert :ok = SQLiteStorage.index_document("a_b%/file.md", "exact", [])
    assert :ok = SQLiteStorage.index_document("axbanything/file.md", "wildcard", [])

    assert {:ok, 0} = PurgeIndices.purge(SQLiteStorage, [])
    assert {:ok, 1} = PurgeIndices.purge(SQLiteStorage, ["a_b%/"])

    {:ok, %{rows: rows}} =
      SQLite.query(db, "SELECT json_extract(data, '$.path') FROM nodes ORDER BY 1")

    remaining = rows |> List.flatten() |> Enum.reject(&is_nil/1)
    assert remaining == ["axbanything/file.md"]
  end

  test "delegates to the active SQLite storage adapter" do
    assert :ok = SQLiteStorage.index_document("tmp/purge_via_port.md", "ephemeral", [])
    assert :ok = SQLiteStorage.index_document("lib/keep_via_port.md", "permanent", [])

    output =
      capture_io(fn ->
        assert {:ok, 1} = PurgeIndices.purge()
      end)

    assert output == ""
    assert {:ok, []} = SQLiteStorage.search_documents("ephemeral", 5)

    assert {:ok, [%{source: "lib/keep_via_port.md"}]} =
             SQLiteStorage.search_documents("permanent", 5)
  end
end
