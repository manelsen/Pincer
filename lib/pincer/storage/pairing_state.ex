defmodule Pincer.Storage.PairingState do
  @moduledoc """
  Ecto schema for durable pairing state persistence.

  Stores the sender-to-agent bindings that survive Docker restarts.
  This replaces the DETS-based pairing_store which was stored inside
  the `sessions/` volume and lost on container restart.

  ## Schema

  | Field       | Type              | Description                              |
  |-------------|-------------------|------------------------------------------|
  | channel     | string            | Channel (:telegram, :discord, :whatsapp)  |
  | sender_id   | string            | External user identifier on the channel   |
  | agent_id    | string            | Bound root-agent ID                      |
  | paired_at   | utc_datetime_usec | When the pairing was established         |
  | raw_data    | map               | Additional pairing metadata               |
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  schema "pairing_state" do
    field(:channel, :string, primary_key: true)
    field(:sender_id, :string, primary_key: true)
    field(:agent_id, :string)
    field(:paired_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})
    field(:raw_data, :map, default: %{})

    timestamps()
  end

  @required [:channel, :sender_id]
  @optional [:agent_id, :raw_data]

@type t :: %__MODULE__{} | %Pincer.Storage.PairingState{}

  @spec changeset(t() | %Pincer.Storage.PairingState{}, map()) :: Ecto.Changeset.t()
  def changeset(pairing_state \\ %__MODULE__{}, params) do
    pairing_state
    |> cast(params, @required ++ @optional)
    |> validate_required(@required)
  end
end
