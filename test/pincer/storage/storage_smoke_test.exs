defmodule Pincer.StorageSmokeTest do
  @moduledoc """
  Smoke test to verify the embedded SQLite defaults exposed through the Storage port.
  """
  use ExUnit.Case

  alias Pincer.Infra.SQLite

  setup do
    Application.ensure_all_started(:pincer)
    :ok
  end

  test "storage port is configured with the SQLite adapter" do
    adapter = Application.get_env(:pincer, :storage_adapter)
    assert adapter == Pincer.Storage.Adapters.SQLite
  end

  test "SQLite engine uses the test database path" do
    assert SQLite.db_path() == ":memory:"
    assert GenServer.whereis(SQLite) != nil
  end
end
