defmodule Pincer.Config.TelegexCallerTest do
  use ExUnit.Case, async: true

  test "Telegex uses Finch request options, not a pool name" do
    assert Telegex.Caller.Adapter.impl() == Telegex.Caller.Adapter.Finch
    refute Keyword.has_key?(Telegex.Caller.Adapter.options(), :name)
  end
end
