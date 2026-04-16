defmodule Pincer.Core.Session.HordeSupervisor do
  @moduledoc """
  Cluster-wide dynamic supervisor for session processes, backed by Horde.

  Works identically to `Pincer.Core.Session.Supervisor` but sessions can be
  spawned and looked up on any node in the cluster.  On a single node the
  behaviour is identical to a plain `DynamicSupervisor`.

  `Pincer.Core.Cluster.NodeObserver` keeps the Horde membership list in sync
  whenever nodes join or leave the cluster.
  """

  use Horde.DynamicSupervisor

  def start_link(opts \\ []) do
    Horde.DynamicSupervisor.start_link(__MODULE__, opts,
      name: __MODULE__,
      distribution_strategy: Horde.UniformDistribution
    )
  end

  @impl true
  def init(opts) do
    Horde.DynamicSupervisor.init(
      Keyword.merge(
        [strategy: :one_for_one, distribution_strategy: Horde.UniformDistribution],
        opts
      )
    )
  end

  @doc "Start a session process cluster-wide."
  @spec start_session(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(session_id, opts \\ []) when is_binary(session_id) do
    child_spec = {Pincer.Core.Session.Server, Keyword.put(opts, :session_id, session_id)}
    Horde.DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc "Terminate a session cluster-wide."
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    case Horde.Registry.lookup(Pincer.Core.Session.HordeRegistry, session_id) do
      [{pid, _}] -> Horde.DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end
end
