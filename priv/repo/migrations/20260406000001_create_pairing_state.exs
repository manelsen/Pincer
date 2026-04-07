defmodule Pincer.Repo.Migrations.CreatePairingState do
  use Ecto.Migration

  def change do
    create table(:pairing_state, primary_key: false) do
      add :channel, :string, primary_key: true
      add :sender_id, :string, primary_key: true
      add :agent_id, :string
      add :paired_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :raw_data, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:pairing_state, [:agent_id]))
    create(index(:pairing_state, [:paired_at]))
  end
end
