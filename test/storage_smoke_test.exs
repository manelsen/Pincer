defmodule Pincer.StorageSmokeTest do
  @moduledoc """
  Smoke test to verify PostgreSQL defaults via the Storage Port.
  """
  use ExUnit.Case

  setup do
    # Ensure the app and Repo are started
    Application.ensure_all_started(:pincer)
    :ok
  end

  test "storage port is configured" do
    adapter = Application.get_env(:pincer, :storage_adapter)
    assert adapter == Pincer.Storage.Adapters.Postgres
  end

  test "repo is using postgres adapter" do
    config = Pincer.Infra.Repo.config()
    assert config[:adapter] == Ecto.Adapters.Postgres
    assert config[:database] == "pincer_test"
    assert config[:hostname] == "localhost"
  end
end
