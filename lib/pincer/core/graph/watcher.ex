defmodule Pincer.Core.Graph.Watcher do
  @moduledoc """
  Watcher process that monitors a specific workspace filesystem for changes 
  and updates the knowledge graph.
  """
  use GenServer
  require Logger
  alias Pincer.Core.Graph.Sync

  def start_link(opts) do
    # We remove the hardcoded name: __MODULE__ to allow multiple instances
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    workspace_root = Keyword.fetch!(opts, :workspace_root)

    # 1. Start File System Watcher for the specific workspace
    {:ok, watcher_pid} = FileSystem.start_link(dirs: [workspace_root])
    FileSystem.subscribe(watcher_pid)

    Logger.info("[GRAPH-WATCHER] Started for workspace: #{workspace_root}")

    # 2. Initial Sync for this specific workspace
    Sync.sync_git(workspace_root)

    {:ok, %{watcher_pid: watcher_pid, pending_timers: %{}, workspace_root: workspace_root}}
  end

  @impl true
  def handle_info({:file_event, _pid, {abs_path, events}}, state) do
    # Filter for relevant events: modified, created, renamed
    if Enum.any?(events, &(&1 in [:modified, :created, :renamed])) do
      rel_path = Path.relative_to(abs_path, state.workspace_root)

      # Cancel existing timer for this file if it hasn't fired yet
      if timer = Map.get(state.pending_timers, rel_path) do
        Process.cancel_timer(timer)
      end

      # We debounce re-indexing a bit to avoid CPU spikes during large saves
      new_timer = Process.send_after(self(), {:debounce_index, abs_path}, 3000)

      {:noreply, %{state | pending_timers: Map.put(state.pending_timers, rel_path, new_timer)}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:debounce_index, abs_path}, state) do
    # Perform the actual indexing within the workspace
    Sync.index_file(abs_path, state.workspace_root)

    rel_path = Path.relative_to(abs_path, state.workspace_root)

    # Remove from pending list
    {:noreply, %{state | pending_timers: Map.delete(state.pending_timers, rel_path)}}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
