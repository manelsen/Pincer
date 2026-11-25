defmodule Pincer.Core.Graph.SyncTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Graph.Sync

  defmodule Git do
    @behaviour Pincer.Ports.Git

    @impl true
    def files(workspace, query) do
      send(self(), {:git_query, workspace, query})
      Process.get({__MODULE__, :files})
    end

    @impl true
    def ensure_branch(_name, _opts), do: {:error, :unused_in_graph}
  end

  setup do
    previous = Application.fetch_env!(:pincer, :git_adapter)
    Application.put_env(:pincer, :git_adapter, Git)
    on_exit(fn -> Application.put_env(:pincer, :git_adapter, previous) end)
  end

  @tag :tmp_dir
  test "indexes supported paths from the requested Git query", %{tmp_dir: workspace} do
    Process.put({Git, :files}, {:ok, ["notes.md", "asset.png"]})

    assert {:ok, ["notes.md"]} = Sync.sync_git(workspace)
    assert_received {:git_query, ^workspace, :changed}
    assert {:ok, ["notes.md"]} = Sync.sync_full(workspace)
    assert_received {:git_query, ^workspace, :tracked}
  end

  @tag :tmp_dir
  test "skips Git for a plain workspace and returns adapter errors", %{tmp_dir: workspace} do
    Process.put({Git, :files}, {:error, :not_a_repository})
    assert {:ok, []} = Sync.sync_git(workspace)
    assert {:ok, []} = Sync.sync_full(workspace)

    Process.put({Git, :files}, {:error, :git_failed})
    assert {:error, :git_failed} = Sync.sync_git(workspace)
  end
end
