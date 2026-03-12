defmodule Pincer.Application do
  @moduledoc """
  OTP Application callback module for Pincer.

  This module implements the `Application` behaviour and is responsible for
  starting the Pincer supervision tree when the application boots.

  ## Supervision Tree

  Pincer uses a `one_for_one` strategy, meaning if a child process crashes,
  only that process is restarted. The tree is structured as follows:

      Pincer.Supervisor (one_for_one)
      │
      ├── Pincer.Infra.PubSub
      │   Message broadcasting for real-time events
      │
      ├── Pincer.Finch
      │   HTTP client pool for API requests
      │
      ├── Pincer.Infra.Repo
      │   Database connection pool (Ecto)
      │
      ├── Pincer.Core.Heartbeat
      │   Periodic health checks and maintenance
      │
      ├── Pincer.Dispatcher.Registry
      │   Registry for message dispatchers (duplicate keys)
      │
      ├── Pincer.MCP.Supervisor
      │   DynamicSupervisor for MCP server connections
      │
      ├── Pincer.Adapters.Connectors.MCP.Manager
      │   MCP server lifecycle and tool discovery
      │
      ├── Pincer.Core.Session.Registry
      │   Registry for active sessions (unique keys)
      │
      ├── Pincer.Core.HookDispatcher
      │   Lifecycle hook registry and dispatcher
      │
      ├── Pincer.Core.Session.Supervisor
      │   DynamicSupervisor for user sessions
      │
      ├── Pincer.Adapters.Cron.Scheduler
      │   Job scheduling and execution
      │
      ├── Pincer.Channels.Supervisor
      │   Channel adapters (Telegram, etc.)
      │
      ├── Pincer.Channels.Telegram.SessionSupervisor
      │   Telegram-specific session management
      │
      └── Pincer.Core.Reloader (dev only)
          Hot code reloading in development

  ## Startup Sequence

  1. Load configuration from `Pincer.Infra.Config`
  2. Initialize PubSub for event broadcasting
  3. Start Finch HTTP client pool
  4. Connect to database
  5. Initialize MCP connections
  6. Start session management
  7. Enable channel adapters
  8. (In dev) Start code reloader

  ## Development Mode

  In development, an additional `Pincer.Core.Reloader` process is started
  to enable hot code reloading without restarting the application.

  ## Configuration

  The application reads configuration from:

  - `config/config.exs` - Application-level config
  - `Pincer.Infra.Config` module - Runtime config loading
  - Environment variables - Secrets and overrides

  ## See Also

  - `Pincer.Core.Session.Supervisor` - Session lifecycle management
  - `Pincer.Adapters.Connectors.MCP.Manager` - MCP tool discovery
  - `Pincer.Infra.PubSub` - Event broadcasting
  """

  use Application

  @impl true
  @doc """
  Starts the Pincer application supervision tree.

  Called automatically by the BEAM when the application starts.
  Should not be called directly.

  ## Parameters

  - `_type` - Application start type (ignored, always `:normal`)
  - `_args` - Application arguments (ignored)

  ## Returns

  - `{:ok, pid}` - Supervisor started successfully
  - `{:error, reason}` - Startup failed

  """
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    File.mkdir_p!("logs")
    Pincer.Infra.Config.load()

    repo_config = Pincer.Infra.Config.get(:repo)

    IO.puts("Starting Bot...")

    IO.puts(
      "Enabled channels whitelist: #{inspect(Application.get_env(:pincer, :enabled_channels))}"
    )

    children = [
      Pincer.Infra.PubSub,
      Pincer.Core.Orchestration.Blackboard,
      Pincer.Core.MemoryObservability,
      {Finch, name: Pincer.Finch},
      {Pincer.Infra.Repo, repo_config},
      Pincer.Core.Heartbeat,
      {Registry, keys: :duplicate, name: Pincer.Dispatcher.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Pincer.MCP.Supervisor},
      Pincer.Adapters.Connectors.MCP.Manager,
      {Registry, keys: :unique, name: Pincer.Core.Session.Registry},
      Pincer.Core.HookDispatcher,
      Pincer.Core.Session.Supervisor,
      Pincer.Core.Project.Registry,
      Pincer.Core.Project.Supervisor,
      Pincer.Adapters.Cron.Scheduler,
      Pincer.Channels.Supervisor,
      Pincer.Channels.Telegram.SessionSupervisor,
      Pincer.Channels.Discord.SessionSupervisor,
      Pincer.Channels.WhatsApp.SessionSupervisor
    ]

    children =
      if Application.get_env(:pincer, :enable_graph_watcher, true) do
        children ++ [Pincer.Core.Graph.Watcher]
      else
        children
      end

    children =
      if Application.get_env(:pincer, :enable_heartbeat_watchers, true) do
        children ++ [Pincer.Core.Heartbeat.GitHubWatcher]
      else
        children
      end

    # Only start Code Reloader in dev env
    children =
      if Application.get_env(:pincer, :enable_browser, false) do
        children ++ [Pincer.Adapters.Browser.Pool]
      else
        children
      end

    children =
      if Mix.env() == :dev do
        children ++ [Pincer.Core.Reloader]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Pincer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
