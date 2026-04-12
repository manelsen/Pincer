defmodule Pincer.Infra.CircuitBreakerSnapshot do
  @moduledoc """
  Ecto schema for persisting circuit breaker state across node restarts.

  Only the `:open` and `:half_open` states are persisted — `:closed` is the
  default and does not need to be stored. On node startup, the CircuitBreaker
  reloads persisted open states and recalculates whether recovery time has
  elapsed, so a restarted node continues cooldown rather than treating all
  providers as healthy.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:name, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: false]

  schema "circuit_breaker_snapshots" do
    field :state, :string, default: "closed"
    field :failure_count, :integer, default: 0
    field :last_failure_at, :utc_datetime_usec
    field :opened_at, :utc_datetime_usec

    timestamps()
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:name, :state, :failure_count, :last_failure_at, :opened_at])
    |> validate_required([:name, :state])
    |> validate_inclusion(:state, ~w(closed open half_open))
    |> validate_number(:failure_count, greater_than_or_equal_to: 0)
  end
end
