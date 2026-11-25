defmodule Pincer.Ports.PubSub do
  @moduledoc "Root transition module for the shared `PincerPorts.PubSub` contract."

  @doc "Subscribes the calling process to a topic."
  defdelegate subscribe(topic), to: PincerPorts.PubSub

  @doc "Removes the calling process's subscription to a topic."
  defdelegate unsubscribe(topic), to: PincerPorts.PubSub

  @doc "Sends a message to the subscribers of a topic."
  defdelegate broadcast(topic, message), to: PincerPorts.PubSub
end
