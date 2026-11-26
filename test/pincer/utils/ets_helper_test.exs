defmodule Pincer.Utils.ETSHelperTest do
  use ExUnit.Case, async: true

  alias Pincer.Utils.ETSHelper
  alias Pincer.Utils.ETSTableHeir

  test "ensure_named_table/2 returns :created then :existing for same table" do
    table = :"ets_helper_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case :ets.whereis(table) do
        :undefined -> :ok
        _ -> :ets.delete(table)
      end
    end)

    assert :created =
             ETSHelper.ensure_named_table(table,
               options: [:named_table, :set, :public, read_concurrency: true]
             )

    assert :existing =
             ETSHelper.ensure_named_table(table,
               options: [:named_table, :set, :public, read_concurrency: true]
             )
  end

  test "a table outlives the process that created it" do
    table = :"ets_helper_heir_test_#{System.unique_integer([:positive])}"
    parent = self()

    on_exit(fn ->
      case :ets.whereis(table) do
        :undefined -> :ok
        _ -> :ets.delete(table)
      end
    end)

    pid =
      spawn(fn ->
        :created = ETSHelper.ensure_named_table(table)
        :ets.insert(table, {:key, :value})
        send(parent, :created)
      end)

    ref = Process.monitor(pid)
    assert_receive :created
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    # The creator is gone; the table and its contents are not.
    assert :existing = ETSHelper.ensure_named_table(table)
    assert [{:key, :value}] = :ets.lookup(table, :key)
    assert :ets.info(table, :owner) == Process.whereis(ETSTableHeir)
  end

  test "an explicit heir is not overridden" do
    table = :"ets_helper_explicit_heir_#{System.unique_integer([:positive])}"

    keeper =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      Process.exit(keeper, :kill)

      case :ets.whereis(table) do
        :undefined -> :ok
        _ -> :ets.delete(table)
      end
    end)

    assert :created =
             ETSHelper.ensure_named_table(table,
               options: [:named_table, :set, :public, {:heir, keeper, :custom}]
             )

    assert :ets.info(table, :owner) == self()
  end
end
