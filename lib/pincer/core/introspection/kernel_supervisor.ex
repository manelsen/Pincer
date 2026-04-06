defmodule Pincer.Core.Introspection.Kernel.Supervisor do
  @moduledoc """
  DynamicSupervisor managing Consciousness Kernel processes.

  Each agent gets one Kernel process, responsible for orchestrating
  introspection activities (reflection, lesson extraction, wakefulness).
  """
  use DynamicSupervisor

  alias Pincer.Core.Introspection.Kernel

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a Kernel for the given agent. Idempotent — returns existing PID if already running.
  """
  @spec start_kernel(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_kernel(agent_id, opts \\ []) when is_binary(agent_id) do
    child_spec = {Kernel, Keyword.put(opts, :agent_id, agent_id)}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc "Terminates a running Kernel for the given agent."
  @spec stop_kernel(String.t()) :: :ok | {:error, :not_found}
  def stop_kernel(agent_id) do
    case Registry.lookup(Kernel.Registry, agent_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end
end
