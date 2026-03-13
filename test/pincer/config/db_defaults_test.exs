defmodule Pincer.Infra.Config.DBDefaultsTest do
  use ExUnit.Case, async: true

  test "ecto repos uses infra repo" do
    assert Application.get_env(:pincer, :ecto_repos) == [Pincer.Infra.Repo]
  end

  test "test repo uses postgres database defaults" do
    repo_config = Application.get_env(:pincer, Pincer.Infra.Repo, [])

    assert repo_config[:adapter] == Ecto.Adapters.Postgres
    assert repo_config[:database] == "pincer_test"
    assert repo_config[:hostname] == "localhost"
    assert repo_config[:port] == 5432
  end

  test "dev config uses postgres env-driven defaults" do
    contents = File.read!("config/dev.exs")

    assert contents =~ "PINCER_DB_HOST"
    assert contents =~ "PINCER_DB_PORT"
    assert contents =~ "PINCER_DB_NAME"
    assert contents =~ "pincer_dev"
  end

  test "default config yaml points to postgres database defaults" do
    {:ok, config} = YamlElixir.read_from_file("config.yaml")

    assert config["database"]["adapter"] == "Ecto.Adapters.PostgreSQL"
    assert config["database"]["database"] == "pincer"
    assert config["database"]["hostname"] == "localhost"
    assert config["database"]["port"] == 5432
  end
end
