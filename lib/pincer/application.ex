defmodule Pincer.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Pincer.Config.load()
    
    repo_config = Pincer.Config.get(:repo)

    IO.puts("Iniciando Bot...")

    children = [
      # Infraestrutura Base
      Pincer.PubSub,
      
      {Finch, name: Pincer.Finch},
      {Pincer.Repo, repo_config},
      Pincer.AI.Embeddings,
      Pincer.Core.Cron,
      Pincer.Core.Heartbeat,
      {Registry, keys: :duplicate, name: Pincer.Dispatcher.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Pincer.MCP.Supervisor},
      Pincer.Connectors.MCP.Manager,
      {Registry, keys: :unique, name: Pincer.Session.Registry},
      Pincer.Session.Supervisor,
      
      Pincer.Channels.Supervisor,
      Pincer.Channels.Telegram.SessionSupervisor
    ]

    opts = [strategy: :one_for_one, name: Pincer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
