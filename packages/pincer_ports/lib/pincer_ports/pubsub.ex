defmodule PincerPorts.PubSub do
  @moduledoc """
  Channel-facing contract for publishing and subscribing to topic messages.

  The host sets `:pincer, :pubsub_adapter` to a module implementing this
  behaviour. Subscriptions belong to the calling process, and broadcasts send
  the original message to subscribers.
  """

  @callback subscribe(String.t()) :: {:ok, pid()} | {:error, term()}
  @callback unsubscribe(String.t()) :: :ok
  @callback broadcast(String.t(), term()) :: :ok

  @doc "Subscribes the calling process to a topic."
  @spec subscribe(String.t()) :: {:ok, pid()} | {:error, term()}
  def subscribe(topic), do: adapter!().subscribe(topic)

  @doc "Removes the calling process's subscription to a topic."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic), do: adapter!().unsubscribe(topic)

  @doc "Sends an unchanged message term to the subscribers of a topic."
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(topic, message), do: adapter!().broadcast(topic, message)

  defp adapter! do
    case Application.fetch_env(:pincer, :pubsub_adapter) do
      {:ok, adapter} when is_atom(adapter) and not is_nil(adapter) and not is_boolean(adapter) ->
        adapter

      {:ok, invalid} ->
        raise ArgumentError,
              "invalid :pubsub_adapter configuration for :pincer: #{inspect(invalid)}"

      :error ->
        raise ArgumentError, "missing :pubsub_adapter configuration for :pincer"
    end
  end
end
