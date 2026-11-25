defmodule Pincer.Infra.Config.DBDefaultsTest do
  use ExUnit.Case, async: true

  test "does not configure a database repo" do
    assert Application.get_env(:pincer, :repo) == nil
  end

  test "test config uses the embedded SQLite backend" do
    assert Application.get_env(:pincer, :storage_adapter) == Pincer.Adapters.Storage.SQLite
    assert Application.get_env(:pincer, :sqlite_path) == ":memory:"
    assert Application.get_env(:pincer, :sqlite_vec) == :auto
  end

  test "dev config uses the SQLite path env var" do
    contents = File.read!("config/dev.exs")

    assert contents =~ "PINCER_SQLITE_PATH"
    assert contents =~ "sqlite_path"
    refute contents =~ "PINCER_DB_"
  end

  test "default config yaml points to the embedded SQLite backend" do
    {:ok, config} = YamlElixir.read_from_file("config.yaml")

    assert get_in(config, ["storage", "adapter"]) == "sqlite"
    assert get_in(config, ["storage", "path"]) == "data/pincer.db"
    refute Map.has_key?(config, "database")
  end
end
