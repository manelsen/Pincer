defmodule Pincer.Repo.Migrations.CreateCircuitBreakerSnapshots do
  use Ecto.Migration

  def change do
    create table(:circuit_breaker_snapshots, primary_key: false) do
      add :name, :string, primary_key: true
      add :state, :string, null: false, default: "closed"
      add :failure_count, :integer, null: false, default: 0
      add :last_failure_at, :utc_datetime_usec
      add :opened_at, :utc_datetime_usec

      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
