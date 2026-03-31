defmodule Pincer.Repo.Migrations.CreateAuditLog do
  use Ecto.Migration

  def change do
    create table(:audit_log, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :event_type, :string, null: false
      add :actor, :string
      add :target, :string
      add :channel, :string
      add :session_id, :string
      add :outcome, :string, null: false
      add :metadata, :map, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:audit_log, [:event_type])
    create index(:audit_log, [:actor])
    create index(:audit_log, [:session_id])
    create index(:audit_log, [:inserted_at])
  end
end
