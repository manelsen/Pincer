defmodule Pincer.Infra.SQLiteVecTest do
  use ExUnit.Case, async: false

  alias Pincer.Infra.SQLite
  alias Pincer.Storage.Adapters.SQLite, as: SQLiteStorage

  setup do
    path =
      System.get_env("PINCER_SQLITE_VEC_PATH") ||
        Path.expand("priv/sqlite_vec/vec0.so")

    if File.regular?(path) do
      previous_server = Application.get_env(:pincer, :sqlite_server)

      pid =
        start_supervised!(
          {SQLite, name: nil, db_path: ":memory:", vec_dimensions: 4, vec_path: path}
        )

      Application.put_env(:pincer, :sqlite_server, pid)

      on_exit(fn ->
        if previous_server do
          Application.put_env(:pincer, :sqlite_server, previous_server)
        else
          Application.delete_env(:pincer, :sqlite_server)
        end
      end)

      {:ok, sqlite: pid, vec_path: path, skip: false}
    else
      {:ok, sqlite: nil, skip: true}
    end
  end

  test "loads sqlite-vec and ranks documents through vec0 KNN", %{sqlite: sqlite, skip: skip} do
    if skip do
      :ok
    else
      assert SQLite.vec_enabled?(sqlite)

      assert :ok =
               SQLiteStorage.index_memory(
                 "mem/close.md",
                 "close vector",
                 "semantic",
                 [1.0, 0.0, 0.0, 0.0]
               )

      assert :ok =
               SQLiteStorage.index_memory(
                 "mem/far.md",
                 "far vector",
                 "semantic",
                 [0.0, 1.0, 0.0, 0.0]
               )

      assert {:ok, [first | _]} =
               SQLiteStorage.search_similar("document", [1.0, 0.0, 0.0, 0.0], 5)

      assert first.source == "mem/close.md"
      assert first.signal == :semantic

      assert {:ok, %{rows: [[2]]}} =
               SQLite.query(sqlite, "SELECT COUNT(*) FROM vec_nodes", [])
    end
  end

  test "forget_memory and purge keep vec_nodes in sync", %{sqlite: sqlite, skip: skip} do
    if skip do
      :ok
    else
      for path <- ["mem/a.md", "mem/b.md"] do
        assert :ok =
                 SQLiteStorage.index_memory(
                   path,
                   "vector",
                   "semantic",
                   [1.0, 0.0, 0.0, 0.0]
                 )
      end

      assert :ok = SQLiteStorage.forget_memory("mem/a.md")
      assert {:ok, %{rows: [[1]]}} = SQLite.query(sqlite, "SELECT COUNT(*) FROM vec_nodes", [])

      assert {:ok, 2} = SQLiteStorage.purge_invalid_documents(["mem/"])
      assert {:ok, %{rows: [[0]]}} = SQLite.query(sqlite, "SELECT COUNT(*) FROM vec_nodes", [])
    end
  end
end
