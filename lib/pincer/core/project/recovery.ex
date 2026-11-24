defmodule Pincer.Core.Project.Recovery do
  @moduledoc """
  Restarts persisted projects that were active when the VM stopped.

  Only `:running` and `:planning` snapshots are rehydrated at boot. Paused,
  awaiting-approval, errored, completed, and stopped projects stay on disk and
  are started on demand by `Pincer.Core.Project.Server.ensure_started/1`.
  """
  use GenServer
  require Logger

  alias Pincer.Core.Project.Server
  alias Pincer.Core.Project.Store

  @statuses [:running, :planning]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, nil, {:continue, :recover}}

  @impl true
  def handle_continue(:recover, state) do
    case Store.list(kind: "server", status: @statuses, limit: 500) do
      {:ok, projects} ->
        Enum.each(projects, &restart/1)

      {:error, reason} ->
        Logger.warning("[PROJECT] Recovery scan failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp restart(project) do
    case Server.ensure_started(project.id) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[PROJECT] Could not recover #{project.id}: #{inspect(reason)}")
    end
  end
end
