defmodule Pincer.StorageSmokeTest do
  @moduledoc """
  Smoke test to verify SQLite connection via the Storage Port.
  """
  use ExUnit.Case

  setup do
    # Ensure the app and Repo are started
    Application.ensure_all_started(:pincer)
    :ok
  end

  test "storage port is configured" do
    adapter = Application.get_env(:pincer, :storage_adapter)
    assert adapter == Pincer.Storage.Adapters.SQLite
  end

  test "repo is using sqlite3 adapter" do
    config = Pincer.Repo.config()
    assert config[:adapter] == Ecto.Adapters.SQLite3
    # In test env, it uses db/pincer_test.db from test.exs
    assert config[:database] =~ "pincer_test.db"
  end
end
