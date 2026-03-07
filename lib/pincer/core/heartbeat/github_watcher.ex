defmodule Pincer.Core.Heartbeat.GitHubWatcher do
  @moduledoc """
  Proactive watcher that checks GitHub repositories for new releases or commits.
  """
  use GenServer
  require Logger

  @check_interval 4 * 60 * 60 * 1000 # 4 hours

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # List of repos to watch (can be moved to config.yaml)
    watched_repos = opts[:repos] || ["odin-lang/Odin", "gleam-lang/gleam"]
    
    schedule_check(10_000) # Check 10s after boot
    
    {:ok, %{repos: watched_repos, last_hashes: %{}}}
  end

  @impl true
  def handle_info(:check_github, state) do
    Logger.info("[GITHUB-WATCHER] Proactively checking for updates...")
    
    new_hashes = Enum.reduce(state.repos, state.last_hashes, fn repo, acc ->
      case fetch_latest_commit(repo) do
        {:ok, hash} ->
          old_hash = Map.get(state.last_hashes, repo)
          
          if old_hash && old_hash != hash do
            notify_update(repo, hash)
          end
          
          Map.put(acc, repo, hash)

        _ -> acc
      end
    end)

    schedule_check(@check_interval)
    {:noreply, %{state | last_hashes: new_hashes}}
  end

  defp fetch_latest_commit(repo) do
    token = System.get_env("GITHUB_PERSONAL_ACCESS_TOKEN")
    url = "https://api.github.com/repos/#{repo}/commits/master" # Or main
    
    case Req.get(url, auth: {:bearer, token}) do
      {:ok, %{status: 200, body: %{"sha" => hash}}} -> {:ok, hash}
      _ ->
        # Try main branch
        url_main = "https://api.github.com/repos/#{repo}/commits/main"
        case Req.get(url_main, auth: {:bearer, token}) do
          {:ok, %{status: 200, body: %{"sha" => hash}}} -> {:ok, hash}
          _ -> {:error, :failed}
        end
    end
  end

  defp notify_update(repo, _hash) do
    _msg = "📢 **Proactive Update**: New activity detected in `#{repo}` repository. Should I analyze the changes?"
    # Find active sessions to notify or notify a default admin chat
    # For now, let's just log it and broadcast to system
    Logger.info("[GITHUB-WATCHER] New activity in #{repo}!")
  end

  defp schedule_check(delay) do
    Process.send_after(self(), :check_github, delay)
  end
end
