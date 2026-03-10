defmodule Pincer.Infra.PostgrexTypesTest do
  use ExUnit.Case, async: true

  test "loads the pgvector-aware Postgrex type module" do
    assert Code.ensure_loaded?(Pincer.Infra.PostgrexTypes)
  end
end
