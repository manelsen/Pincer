defmodule Pincer.Infra.Repo.Migrations.CreateSelfStates do
  use Ecto.Migration

  def change do
    create table(:self_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, :string, null: false
      add :wakefulness, :string, null: false, default: "idle"
      add :focus, :string, default: ""
      add :concerns, {:array, :string}, default: []
      add :open_questions, {:array, :string}, default: []
      add :work_lanes, {:array, :map}, default: []
      add :last_reflection_summary, :text, default: ""
      add :mood_valence, :float, default: 0.0
      add :mood_arousal, :float, default: 0.0
      add :meta, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:self_states, [:agent_id])
  end
end
