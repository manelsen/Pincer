defmodule Pincer.Ports.Session do
  @moduledoc """
  Port for driving agent sessions from a channel adapter.

  Channels should never reach into `Pincer.Core.Session.*` directly: doing so
  couples every transport package to the agent runtime and makes the packages
  unpublishable on their own. This port exposes the operations a channel needs
  (route an inbound message, read status, switch model, ensure a session
  process exists) and leaves the implementation to whoever registers it.

  The implementation is resolved at runtime from `:session_adapter`, mirroring
  `Pincer.Ports.LLM`. In the full application it points at
  `Pincer.Core.Session.Adapter`; in a package test it can point at a stub.

  ## Example

      Pincer.Ports.Session.process_input(session_id, incoming_message)
  """

  @typedoc "Opaque inbound payload, built by the channel."
  @type input :: term()

  @typedoc "Session lifecycle status."
  @type status :: term()

  @callback process_input(String.t(), input()) :: term()
  @callback get_status(String.t()) :: status()
  @callback reset(String.t()) :: term()
  @callback set_model(String.t(), String.t(), String.t()) :: term()
  @callback set_thinking(String.t(), term()) :: term()
  @callback set_reasoning_visible(String.t(), boolean()) :: term()
  @callback set_verbose(String.t(), boolean()) :: term()
  @callback set_usage(String.t(), term()) :: term()
  @callback start_session(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  @callback stop_session(String.t()) :: term()
  @callback ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}

  @doc """
  Name of the registry where per-sender channel workers register themselves.

  Channels need this to build `{:via, Registry, {name, key}}` tuples without
  referencing the Core module that happens to hold the name today.
  """
  @spec registry() :: atom()
  def registry do
    Application.get_env(:pincer, :session_registry, Pincer.Core.Session.Registry)
  end

  @doc false
  def adapter do
    Application.get_env(:pincer, :session_adapter, Pincer.Core.Session.Adapter)
  end

  def process_input(session_id, input), do: adapter().process_input(session_id, input)
  def get_status(session_id), do: adapter().get_status(session_id)
  def reset(session_id), do: adapter().reset(session_id)
  def set_model(session_id, provider, model), do: adapter().set_model(session_id, provider, model)
  def set_thinking(session_id, level), do: adapter().set_thinking(session_id, level)

  def set_reasoning_visible(session_id, visible),
    do: adapter().set_reasoning_visible(session_id, visible)

  def set_verbose(session_id, verbose), do: adapter().set_verbose(session_id, verbose)
  def set_usage(session_id, level), do: adapter().set_usage(session_id, level)
  def start_session(session_id, opts), do: adapter().start_session(session_id, opts)
  def stop_session(session_id), do: adapter().stop_session(session_id)
  def ensure_started(session_id, opts), do: adapter().ensure_started(session_id, opts)
end
