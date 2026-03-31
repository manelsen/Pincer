defmodule Pincer.Repo.Migrations.CreateDeadLetterQueue do
  use Ecto.Migration

  def change do
    create table(:dead_letter_queue, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :operation_type, :string, null: false
      add :payload, :map, null: false
      add :error, :string
      add :attempt_count, :integer, default: 1, null: false
      add :last_attempted_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec
      add :resolution, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:dead_letter_queue, [:operation_type])
    create index(:dead_letter_queue, [:resolved_at])
    create index(:dead_letter_queue, [:inserted_at])
  end
end
