defmodule Pincer.E2E.ZeroInfraSQLiteBootE2ETest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Pincer.PurgeIndices
  alias Pincer.Core.StartupGuard
  alias Pincer.Infra.SQLite
  alias Pincer.Ports.Storage
  alias Pincer.Storage.Adapters.SQLite, as: SQLiteStorage

  setup do
    keys = [
      :storage_adapter,
      :sqlite_server,
      :sqlite_path,
      :config_path,
      :skip_startup_guard
    ]

    snapshot = Map.new(keys, fn k -> {k, Application.get_env(:pincer, k, :__unset__)} end)

    on_exit(fn ->
      Enum.each(snapshot, fn
        {k, :__unset__} -> Application.delete_env(:pincer, k)
        {k, v} -> Application.put_env(:pincer, k, v)
      end)
    end)

    :ok
  end

  test "boots isolated file-backed SQLite engine, passes StartupGuard, purges invalid indices, and survives restart" do
    tmp = Path.join(System.tmp_dir!(), "pincer_zi_e2e_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    db_path = Path.join(tmp, "data/e2e_zero_infra.db")
    cfg_path = Path.join(tmp, "config.yaml")

    File.write!(cfg_path, """
    storage:
      adapter: "sqlite"
      path: "#{db_path}"
    channels:
      cli:
        enabled: true
    """)

    pid = start_supervised!({SQLite, name: nil, db_path: db_path})
    Application.put_env(:pincer, :storage_adapter, SQLiteStorage)
    Application.put_env(:pincer, :sqlite_server, pid)
    Application.put_env(:pincer, :sqlite_path, db_path)
    Application.put_env(:pincer, :config_path, cfg_path)
    Application.put_env(:pincer, :skip_startup_guard, false)

    assert :ok = StartupGuard.run()

    # Messages + FTS5
    assert {:ok, _} =
             Storage.save_message("zi-e2e-sess", "user", "sqlite restart persistence check")

    assert {:ok, [%{kind: :message}]} = Storage.search_messages("persistence", 5)

    # Documents + PurgeIndices
    assert :ok = Storage.index_document("tmp/ephemeral.md", "temporary leaked draft", [0.1, 0.2])
    assert :ok = Storage.index_document("lib/core.ex", "durable architectural spec", [0.1, 0.2])
    assert {:ok, 1} = PurgeIndices.purge()
    assert {:ok, []} = Storage.search_documents("leaked", 5)
    assert {:ok, [%{source: "lib/core.ex"}]} = Storage.search_documents("architectural", 5)

    # Checkpoints & Pairing
    snapshot = :erlang.term_to_binary([%{"role" => "user", "content" => "checkpointed"}])

    assert {:ok, _} =
             Storage.save_checkpoint("zi-e2e-sess", %{history_snapshot: snapshot, step_count: 1})

    assert :ok = Storage.upsert_pairing_state(:cli, "u-e2e", "agent-zi", %{"k" => "v"})

    # Restart SQLite server on same disk file and assert full durability
    stop_supervised!(SQLite)
    restarted = start_supervised!({SQLite, name: nil, db_path: db_path}, id: :sqlite_restarted)
    Application.put_env(:pincer, :sqlite_server, restarted)

    assert [%{role: "user", content: "sqlite restart persistence check"}] =
             Storage.get_messages("zi-e2e-sess")

    assert {:ok, [%{source: "lib/core.ex"}]} = Storage.search_documents("architectural", 5)
    assert {:ok, loaded_chk} = Storage.load_checkpoint("zi-e2e-sess")
    assert loaded_chk.step_count == 1
    assert %{agent_id: "agent-zi"} = Storage.get_pairing_state(:cli, "u-e2e")
  end

  @tag :sqlite_smoke
  test "boots full Pincer.Application supervision tree in SQLite mode" do
    assert Process.whereis(Pincer.Infra.SQLite) != nil

    Application.put_env(:pincer, :skip_startup_guard, false)
    assert :ok = StartupGuard.run()

    session_id = "smoke-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Storage.save_message(session_id, "user", "boot smoke zero infra")
    assert [%{content: "boot smoke zero infra"}] = Storage.get_messages(session_id)
    assert :ok = Storage.index_document("tmp/smoke_junk.md", "transient smoke token", [])
    assert :ok = Storage.index_document("lib/smoke_keep.ex", "kept smoke token", [])
    assert {:ok, count} = PurgeIndices.purge()
    assert count >= 1
    assert {:ok, []} = Storage.search_documents("transient smoke", 5)
    assert {:ok, [%{source: "lib/smoke_keep.ex"} | _]} = Storage.search_documents("kept smoke", 5)

    on_exit(fn ->
      _ = Storage.delete_messages(session_id)

      _ =
        SQLite.execute(
          SQLite.default_server(),
          "DELETE FROM nodes WHERE type = 'document' AND json_extract(data, '$.path') = 'lib/smoke_keep.ex'"
        )
    end)
  end
end
