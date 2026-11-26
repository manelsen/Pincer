defmodule Pincer.Core.Pairing.StoreTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Pairing.Store

  @test_tables %{
    pending: :pincer_pairing_store_test_pending,
    invites: :pincer_pairing_store_test_invites,
    pairs: :pincer_pairing_store_test_pairs
  }

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "pincer_pairing_store_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    store_path = Path.join(tmp_dir, "pairing_store.dets")

    on_exit(fn ->
      delete_table(@test_tables.pending)
      delete_table(@test_tables.invites)
      delete_table(@test_tables.pairs)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, store_path: store_path}
  end

  describe "DETS handle caching and lifecycle" do
    test "opens DETS once per store_path and reuses handle across reads and writes", %{
      store_path: store_path
    } do
      pid =
        start_supervised!(
          {Store, name: nil, store_path: store_path, tables: @test_tables},
          id: :store_reuse
        )

      expanded = Path.expand(store_path)
      dets_name = {:pincer_pairing_store, expanded}

      assert :ok = Store.put_pending({"telegram", "u1"}, %{code: "111111"}, server: pid)
      assert :ok = Store.put_pending({"telegram", "u2"}, %{code: "222222"}, server: pid)
      assert :ok = Store.put_invite({"telegram", "h1"}, %{code: "INV1"}, server: pid)
      assert :ok = Store.delete_pending({"telegram", "u1"}, server: pid)
      assert {:ok, %{code: "222222"}} = Store.get_pending({"telegram", "u2"}, server: pid)
      assert {:ok, %{code: "INV1"}} = Store.get_invite({"telegram", "h1"}, server: pid)

      stats = Store.stats(server: pid)
      assert stats.open_count == 1
      assert stats.open_paths == [expanded]
      assert dets_name in :dets.all()
    end

    test "persists pending and invite entries across GenServer stop/restart and closes DETS on terminate",
         %{store_path: store_path} do
      expanded = Path.expand(store_path)
      dets_name = {:pincer_pairing_store, expanded}

      {:ok, pid1} = Store.start_link(name: nil, store_path: store_path, tables: @test_tables)
      assert :ok = Store.put_pending({"telegram", "persist-u"}, %{code: "999999"}, server: pid1)

      assert :ok =
               Store.put_invite({"discord", "hash-x"}, %{code: "INVX", agent_id: "annie"},
                 server: pid1
               )

      assert dets_name in :dets.all()

      assert :ok = GenServer.stop(pid1)
      refute dets_name in :dets.all()

      # Wipe runtime ETS tables to verify bootstrap restores from disk DETS
      delete_table(@test_tables.pending)
      delete_table(@test_tables.invites)
      delete_table(@test_tables.pairs)

      pid2 =
        start_supervised!(
          {Store, name: nil, store_path: store_path, tables: @test_tables},
          id: :store_restart
        )

      assert {:ok, %{code: "999999"}} = Store.get_pending({"telegram", "persist-u"}, server: pid2)

      assert {:ok, %{code: "INVX", agent_id: "annie"}} =
               Store.get_invite({"discord", "hash-x"}, server: pid2)
    end

    test "close_store/1 closes cached DETS handle and reset/1 clears ETS and DETS", %{
      store_path: store_path,
      tmp_dir: tmp_dir
    } do
      expanded = Path.expand(store_path)
      dets_name = {:pincer_pairing_store, expanded}
      second_path = Path.join(tmp_dir, "second_store.dets")
      second_expanded = Path.expand(second_path)

      {:ok, pid} = Store.start_link(name: nil, store_path: store_path, tables: @test_tables)

      assert :ok = Store.put_pending({"telegram", "u1"}, %{code: "123456"}, server: pid)

      assert :ok =
               Store.put_pending({"telegram", "u2"}, %{code: "654321"},
                 server: pid,
                 store_path: second_path
               )

      stats_both = Store.stats(server: pid)
      assert stats_both.open_count == 2
      assert Enum.sort(stats_both.open_paths) == Enum.sort([expanded, second_expanded])

      assert :ok = Store.close_store(store_path, server: pid)
      refute dets_name in :dets.all()
      assert Store.stats(server: pid).open_paths == [second_expanded]

      # Reopening via reset clears DETS + ETS
      assert :ok = Store.reset(server: pid, store_path: store_path)
      assert :error = Store.get_pending({"telegram", "u1"}, server: pid)
      assert :ok = GenServer.stop(pid)

      delete_table(@test_tables.pending)
      delete_table(@test_tables.invites)
      delete_table(@test_tables.pairs)

      {:ok, pid2} = Store.start_link(name: nil, store_path: store_path, tables: @test_tables)

      assert :error = Store.get_pending({"telegram", "u1"}, server: pid2)
      assert :ok = GenServer.stop(pid2)
    end
  end

  describe "concurrent access and fail-safe fallback" do
    test "handles concurrent mutations safely without DETS lock contention", %{
      store_path: store_path
    } do
      pid =
        start_supervised!(
          {Store, name: nil, store_path: store_path, tables: @test_tables},
          id: :store_concurrent
        )

      results =
        1..20
        |> Task.async_stream(
          fn idx ->
            idx_str = Integer.to_string(idx)
            key = {"telegram", "user-#{idx}"}
            :ok = Store.put_pending(key, %{code: idx_str}, server: pid)
            {:ok, %{code: ^idx_str}} = Store.get_pending(key, server: pid)
            if rem(idx, 2) == 0, do: :ok = Store.delete_pending(key, server: pid)
            {idx, idx_str}
          end,
          max_concurrency: 10
        )
        |> Enum.to_list()

      assert length(results) == 20
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert Store.stats(server: pid).open_count == 1
    end

    test "falls back safely when Store GenServer is not started (--no-start mode)", %{
      store_path: store_path
    } do
      opts = [
        server: :unstarted_pairing_store_for_test,
        store_path: store_path,
        tables: @test_tables
      ]

      assert :ok = Store.reset(opts)
      assert :ok = Store.put_pending({"telegram", "no-start-u"}, %{code: "777777"}, opts)
      assert {:ok, %{code: "777777"}} = Store.get_pending({"telegram", "no-start-u"}, opts)

      assert :ok = Store.put_pair({"telegram", "no-start-p"}, %{agent_id: "annie"}, opts)
      assert Store.paired?({"telegram", "no-start-p"}, opts)
      assert {:ok, %{agent_id: "annie"}} = Store.get_pair({"telegram", "no-start-p"}, opts)

      # Verify DETS file on disk actually persisted in fallback mode
      delete_table(@test_tables.pending)
      assert :ok = Store.ensure_tables(opts)
      assert {:ok, %{code: "777777"}} = Store.get_pending({"telegram", "no-start-u"}, opts)

      assert :ok = Store.reset(opts)
      assert :error = Store.get_pending({"telegram", "no-start-u"}, opts)
    end
  end

  defp delete_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ok
      _ -> :ets.delete(table)
    end
  end
end
