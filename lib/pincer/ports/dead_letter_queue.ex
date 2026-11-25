defmodule Pincer.Ports.DeadLetterQueue do
  @moduledoc "Persistence for failed operations awaiting review or retry."

  @type write_result :: {:ok, map()} | {:error, term()}

  @callback insert(map()) :: write_result()
  @callback pending(String.t() | nil) :: [map()]
  @callback resolve(String.t(), String.t(), DateTime.t()) :: write_result()
  @callback increment_attempt(String.t(), DateTime.t()) :: write_result()

  @doc "Persists a validated failed operation."
  @spec insert(map()) :: write_result()
  def insert(entry), do: adapter().insert(entry)

  @doc "Lists unresolved entries in enqueue order, optionally filtered by operation type."
  @spec pending(String.t() | nil) :: [map()]
  def pending(operation_type), do: adapter().pending(operation_type)

  @doc "Records how and when an entry was resolved."
  @spec resolve(String.t(), String.t(), DateTime.t()) :: write_result()
  def resolve(id, resolution, now), do: adapter().resolve(id, resolution, now)

  @doc "Increments the persisted attempt count and records the attempt time."
  @spec increment_attempt(String.t(), DateTime.t()) :: write_result()
  def increment_attempt(id, now), do: adapter().increment_attempt(id, now)

  defp adapter, do: Application.fetch_env!(:pincer, :dead_letter_queue_adapter)
end
