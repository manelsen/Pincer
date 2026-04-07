defmodule Pincer.Core.PairingStorage do
  @moduledoc """
  Port for durable pairing state persistence.

  Abstracts pairing state storage so `Pincer.Core.Pairing` (in the core app)
  can persist durable bindings without depending on the storage layer.
  The adapter is resolved at compile time via application config.
  """

  @callback upsert(String.t(), String.t(), String.t() | nil, map()) :: :ok | {:error, term()}
  @callback list_by_channel(String.t()) :: [%{optional(atom()) => any()}]

  @adapter Application.compile_env(:pincer, :pairing_storage_adapter, Pincer.Storage.Adapters.Postgres)

  @spec upsert(String.t(), String.t(), String.t() | nil, map()) :: :ok | {:error, term()}
  def upsert(channel, sender_id, agent_id, raw_data \\ %{}) do
    @adapter.upsert_pairing_state(channel, sender_id, agent_id, raw_data)
  end

  @spec list_by_channel(String.t()) :: [%{optional(atom()) => any()}]
  def list_by_channel(channel) do
    @adapter.list_pairing_states_by_channel(channel)
  end
end
