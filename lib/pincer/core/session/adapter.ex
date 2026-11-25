defmodule Pincer.Core.Session.Adapter do
  @moduledoc """
  Implements `PincerPorts.Session` on top of `Pincer.Core.Session.*`.

  Channel packages talk to sessions through the port, so this adapter is the
  one place that knows the concrete server, supervisor and registry names.
  Registered at boot via `config :pincer, :session_adapter, __MODULE__`.
  """

  @behaviour PincerPorts.Session

  alias Pincer.Core.Registry
  alias Pincer.Core.Session.{Server, Supervisor}

  @impl true
  def process_input(session_id, input), do: Server.process_input(session_id, input)

  @impl true
  def get_status(session_id), do: Server.get_status(session_id)

  @impl true
  def reset(session_id), do: Server.reset(session_id)

  @impl true
  def set_model(session_id, provider, model), do: Server.set_model(session_id, provider, model)

  @impl true
  def set_thinking(session_id, level), do: Server.set_thinking(session_id, level)

  @impl true
  def set_reasoning_visible(session_id, visible),
    do: Server.set_reasoning_visible(session_id, visible)

  @impl true
  def set_verbose(session_id, verbose), do: Server.set_verbose(session_id, verbose)

  @impl true
  def set_usage(session_id, level), do: Server.set_usage(session_id, level)

  @impl true
  def approve_all(session_id, seconds), do: Server.approve_all(session_id, seconds)

  @impl true
  def resolve(channel, context, channel_config),
    do: Pincer.Core.SessionResolver.resolve(channel, context, channel_config)

  @impl true
  def start_session(session_id, opts), do: Supervisor.start_session(session_id, opts)

  @impl true
  def stop_session(session_id), do: Supervisor.stop_session(session_id)

  @impl true
  def ensure_started(session_id, opts) do
    case Registry.lookup(Pincer.Core.Session.Registry, session_id, :local) do
      [] -> start_session(session_id, opts)
      [{pid, _}] -> {:ok, pid}
    end
  end
end
