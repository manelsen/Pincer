defmodule Pincer.Core.Session.HordeRegistry do
  @moduledoc """
  Cluster-wide process registry for sessions, backed by Horde.

  Provides the same `via_tuple/1` API as the local `Pincer.Core.Session.Registry`
  so session processes can register themselves without knowing whether they are
  running in a single-node or multi-node deployment.
  """

  use Horde.Registry

  def start_link(opts \\ []) do
    Horde.Registry.start_link(__MODULE__, Keyword.merge([keys: :unique], opts), name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Horde.Registry.init(opts)
  end

  @doc "Returns a `{:via, ...}` tuple for use with `GenServer.start_link/3`."
  @spec via_tuple(String.t()) :: {:via, Horde.Registry, {__MODULE__, String.t()}}
  def via_tuple(session_id) do
    {:via, Horde.Registry, {__MODULE__, session_id}}
  end
end
