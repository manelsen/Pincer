defmodule Pincer.Utils.ETSHelperTest do
  use ExUnit.Case, async: true

  alias Pincer.Utils.ETSHelper

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
end
