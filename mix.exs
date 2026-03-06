defmodule Pincer.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/micelio/pincer"
  @hex_url "https://hex.pm/packages/pincer"

  def project do
    [
      app: :pincer,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [
        externals: [
          {:html_entities, Pincer.Utils}
        ],
        ignore_unknown: true
      ],
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),

      # Hex
      description: description(),
      package: package(),

      # Docs
      name: "Pincer",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :os_mon],
      mod: {Pincer.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      qa: ["format --check-formatted", "test.quick"],
      "test.quick": ["test --stale --max-failures 1"],
      "sprint.check": ["format --check-formatted", "test"]
    ]
  end

  defp deps do
    [
      # HTTP clients
      {:req, "~> 0.5"},
      {:finch, "~> 0.16"},
      {:tesla, "~> 1.9"},
      {:hackney, "~> 1.20"},
      {:multipart, "~> 0.4"},

      # JSON
      {:jason, "~> 1.4"},

      # Database
      {:ecto_sql, "~> 3.11"},
      {:ecto_sqlite3, "~> 0.15"},

      # Messaging
      {:telegex, "~> 1.8"},
      {:nostrum, "~> 0.10", runtime: false},
      {:slack_elixir, "~> 1.2"},
      {:earmark, "~> 1.4"},

      # Config
      {:dotenvy, "~> 1.0"},
      {:yaml_elixir, "~> 2.11"},

      # Scheduling
      {:crontab, "~> 1.1"},

      # Boundary Enforcement
      {:boundary, "~> 0.10", runtime: false},

      # Dev & Hot Reload
      {:mox, "~> 1.0", only: :test},
      {:file_system, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Autonomous AI agent framework built on the BEAM. OTP supervision, MCP integration, sub-agents via Blackboard pattern."
  end

  defp package do
    [
      name: "pincer",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{
        "GitHub" => @source_url,
        "HexDocs" => @hex_url <> "/docs",
        "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: extras(),
      groups_for_modules: groups_for_modules(),
      source_ref: "v#{@version}",
      api_reference: false
    ]
  end

  defp extras do
    [
      "README.md": [title: "Getting Started"],
      "CHANGELOG.md": [title: "Changelog"],
      "SOUL.md": [title: "Philosophy"],
      "AGENTS.md": [title: "Development Protocol"]
    ]
  end

  defp groups_for_modules do
    [
      Core: [
        Pincer,
        Pincer.Tool,
        Pincer.Core.Executor,
        Pincer.Core.SubAgentProgress
      ],
      Session: [
        Pincer.Session.Server,
        Pincer.Session.Supervisor,
        Pincer.Session.Logger
      ],
      LLM: [
        Pincer.LLM.Client
      ],
      MCP: [
        Pincer.Connectors.MCP.Manager,
        Pincer.Connectors.MCP.Client,
        Pincer.Connectors.MCP.Transport,
        Pincer.Connectors.MCP.Transports.Stdio
      ],
      Tools: [
        Pincer.Tools.FileSystem,
        Pincer.Tools.SafeShell,
        Pincer.Tools.Web,
        Pincer.Tools.GitHub,
        Pincer.Tools.Scheduler,
        Pincer.Tools.Orchestrator,
        Pincer.Tools.GraphMemory
      ],
      Orchestration: [
        Pincer.Orchestration.Blackboard,
        Pincer.Orchestration.SubAgent,
        Pincer.Orchestration.Scheduler,
        Pincer.Orchestration.Archivist
      ],
      Channels: [
        Pincer.Channel,
        Pincer.Channels.Telegram,
        Pincer.Channels.CLI,
        Pincer.Channels.Webhook,
        Pincer.Channels.Factory,
        Pincer.Channels.Supervisor
      ],
      Storage: [
        Pincer.Storage,
        Pincer.Storage.Port,
        Pincer.Storage.Message,
        Pincer.Storage.Adapters.SQLite,
        Pincer.Storage.Adapters.Graph,
        Pincer.Storage.Graph.Node,
        Pincer.Storage.Graph.Edge
      ],
      Infrastructure: [
        Pincer.Config,
        Pincer.Infra.PubSub,
        Pincer.Cron.Scheduler,
        Pincer.Cron.Job,
        Pincer.Cron.Storage
      ]
    ]
  end
end
