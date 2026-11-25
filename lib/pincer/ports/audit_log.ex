defmodule Pincer.Ports.AuditLog do
  @moduledoc "Persistence for validated security audit events."

  @type filter :: :all | {:actor, String.t()} | {:type, String.t()}

  @callback insert(map()) :: :ok | {:error, term()}
  @callback list(filter(), integer()) :: [map()]

  @doc "Persists an event with its metadata."
  @spec insert(map()) :: :ok | {:error, term()}
  def insert(event), do: adapter().insert(event)

  @doc "Lists recent matching audit events, newest first."
  @spec list(filter(), integer()) :: [map()]
  def list(filter, limit), do: adapter().list(filter, limit)

  defp adapter, do: Application.fetch_env!(:pincer, :audit_log_adapter)
end
