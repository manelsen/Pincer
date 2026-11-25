defmodule PincerPorts.Session do
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

      PincerPorts.Session.process_input(session_id, incoming_message)
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
  @callback approve_all(String.t(), non_neg_integer()) :: term()
  @callback resolve(atom(), map(), map()) :: term()
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
    fetch_env_atom!(:session_registry)
  end

  @doc false
  def adapter do
    fetch_env_atom!(:session_adapter)
  end

  defp fetch_env_atom!(key) do
    case Application.fetch_env(:pincer, key) do
      {:ok, mod} when is_atom(mod) and not is_nil(mod) and not is_boolean(mod) ->
        mod

      {:ok, invalid} ->
        raise ArgumentError,
              "invalid #{inspect(key)} configuration for :pincer: #{inspect(invalid)}"

      :error ->
        raise ArgumentError,
              "missing #{inspect(key)} configuration for :pincer (configure config :pincer, #{inspect(key)}, ...)"
    end
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
  def approve_all(session_id, seconds \\ 600), do: adapter().approve_all(session_id, seconds)

  def resolve(channel, context, channel_config \\ %{}),
    do: adapter().resolve(channel, context, channel_config)

  def start_session(session_id, opts \\ []), do: adapter().start_session(session_id, opts)
  def stop_session(session_id), do: adapter().stop_session(session_id)
  def ensure_started(session_id, opts), do: adapter().ensure_started(session_id, opts)
end
