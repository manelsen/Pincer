defmodule Mix.Tasks.Pincer.PurgeIndicesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pincer.PurgeIndices
  alias Pincer.Infra.Repo
  alias Pincer.Infra.SQLite
  alias Pincer.Storage.Adapters.Postgres, as: PostgresStorage
  alias Pincer.Storage.Adapters.SQLite, as: SQLiteStorage
  alias Pincer.Storage.Graph.Node

  setup do
    Application.ensure_all_started(:pincer)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(Node)
    :ok
  end

  test "purge/2 deletes matching document nodes under tmp/ and workspaces/ on Postgres adapter" do
    tmp_doc =
      Repo.insert!(%Node{type: "document", data: %{"path" => "tmp/scratch.md"}})

    ws_doc =
      Repo.insert!(%Node{type: "document", data: %{"path" => "workspaces/agent_1/notes.md"}})

    percent_doc =
      Repo.insert!(%Node{type: "document", data: %{"path" => "tmpX/not_matching.md"}})

    valid_doc =
      Repo.insert!(%Node{type: "document", data: %{"path" => "lib/pincer/app.ex"}})

    non_doc_tmp =
      Repo.insert!(%Node{type: "file", data: %{"path" => "tmp/file_node.ex"}})

    no_path_doc =
      Repo.insert!(%Node{type: "document", data: %{"title" => "untitled"}})

    assert {:ok, 2} = PurgeIndices.purge(PostgresStorage)

    remaining_ids =
      Repo.all(Node)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    refute MapSet.member?(remaining_ids, tmp_doc.id)
    refute MapSet.member?(remaining_ids, ws_doc.id)
    assert MapSet.member?(remaining_ids, percent_doc.id)
    assert MapSet.member?(remaining_ids, valid_doc.id)
    assert MapSet.member?(remaining_ids, non_doc_tmp.id)
    assert MapSet.member?(remaining_ids, no_path_doc.id)
  end

  test "purge/2 handles wildcard escapes and empty prefix list on Postgres adapter" do
    exact_doc =
      Repo.insert!(%Node{type: "document", data: %{"path" => "a_b%/file.md"}})

    wildcard_doc =
      Repo.insert!(%Node{type: "document", data: %{"path" => "axbanything/file.md"}})

    assert {:ok, 0} = PurgeIndices.purge(PostgresStorage, [])
    assert {:ok, 1} = PurgeIndices.purge(PostgresStorage, ["a_b%/"])

    refute Repo.get(Node, exact_doc.id)
    assert Repo.get(Node, wildcard_doc.id)
  end

  test "delegates to active storage adapter (SQLite) without touching Postgres Repo" do
    prev_storage = Application.get_env(:pincer, :storage_adapter)
    prev_server = Application.get_env(:pincer, :sqlite_server)

    db_pid = start_supervised!({SQLite, name: nil, db_path: ":memory:"})
    Application.put_env(:pincer, :storage_adapter, SQLiteStorage)
    Application.put_env(:pincer, :sqlite_server, db_pid)

    on_exit(fn ->
      if prev_storage,
        do: Application.put_env(:pincer, :storage_adapter, prev_storage),
        else: Application.delete_env(:pincer, :storage_adapter)

      if prev_server,
        do: Application.put_env(:pincer, :sqlite_server, prev_server),
        else: Application.delete_env(:pincer, :sqlite_server)
    end)

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
