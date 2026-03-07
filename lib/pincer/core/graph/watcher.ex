defmodule Pincer.Core.Graph.Watcher do
  @moduledoc """
  Watcher process that monitors the filesystem for changes and updates the knowledge graph.
  """
  use GenServer
  require Logger
  alias Pincer.Core.Graph.Sync

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # 1. Start File System Watcher
    # We watch the current directory
    {:ok, watcher_pid} = FileSystem.start_link(dirs: [File.cwd!()])
    FileSystem.subscribe(watcher_pid)

    Logger.info("[GRAPH-WATCHER] Started. Monitoring project for knowledge sync.")

    # 2. Initial Sync
    # We do a git sync on boot to catch up
    Sync.sync_git()

    {:ok, %{watcher_pid: watcher_pid}}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, events}}, state) do
    # Filter for relevant events: modified, created, renamed
    if Enum.any?(events, &(&1 in [:modified, :created, :renamed])) do
      # Relative path
      rel_path = Path.relative_to_cwd(path)
      
      # We debounce re-indexing a bit to avoid CPU spikes during large saves
      Process.send_after(self(), {:debounce_index, rel_path}, 2000)
    end
    {:noreply, state}
  end

  def handle_info({:debounce_index, path}, state) do
    Sync.index_file(path)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
