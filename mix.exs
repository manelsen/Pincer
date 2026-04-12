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
      elixirc_options: [warnings_as_errors: true],
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
      extra_applications: [:logger],
      mod: {Pincer.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      qa: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --warnings-as-errors --max-failures 1"
      ],
      "test.quick": ["test --warnings-as-errors --stale --max-failures 1"],
      "sprint.check": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --warnings-as-errors"
      ]
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

      # HTTP server (health endpoint)
      {:bandit, "~> 1.5"},

      # JSON
      {:jason, "~> 1.4"},

      # Database
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.19"},
      {:pgvector, "~> 0.3"},

      # Channel plugins (monorepo path deps)
      {:pincer_ports, path: "packages/pincer_ports", override: true},
      {:pincer_cli, path: "packages/pincer_cli"},

      # LLM provider plugins (monorepo path deps)
      {:pincer_openai_compat, path: "packages/pincer_openai_compat", override: true},
      {:pincer_anthropic, path: "packages/pincer_anthropic"},
      {:pincer_google, path: "packages/pincer_google"},
      {:pincer_openai, path: "packages/pincer_openai"},
      {:pincer_mistral, path: "packages/pincer_mistral"},
      {:pincer_groq, path: "packages/pincer_groq"},
      {:pincer_minimax, path: "packages/pincer_minimax"},
      {:pincer_moonshot, path: "packages/pincer_moonshot"},
      {:pincer_ollama, path: "packages/pincer_ollama"},
      {:pincer_openrouter, path: "packages/pincer_openrouter"},
      {:pincer_deepseek, path: "packages/pincer_deepseek"},
      {:pincer_qwen, path: "packages/pincer_qwen"},
      {:pincer_zhipu, path: "packages/pincer_zhipu"},
      {:pincer_opencode_zen, path: "packages/pincer_opencode_zen"},
      {:pincer_telegram, path: "packages/pincer_telegram"},
      {:pincer_webhook, path: "packages/pincer_webhook"},
      {:pincer_whatsapp, path: "packages/pincer_whatsapp"},
      {:pincer_line, path: "packages/pincer_line"},
      {:pincer_feishu, path: "packages/pincer_feishu"},
      {:pincer_dingtalk, path: "packages/pincer_dingtalk"},
      {:pincer_slack, path: "packages/pincer_slack"},
      {:pincer_discord, path: "packages/pincer_discord"},

      # Messaging
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

      # Observability
      {:prom_ex, "~> 1.11"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_phoenix, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # Dev & Hot Reload
      # Distributed clustering
      {:libcluster, "~> 3.3"},
      {:horde, "~> 0.8"},

      {:mox, "~> 1.0", only: :test},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:benchee, "~> 1.3", only: :bench},
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
        Pincer.Storage.Adapters.Postgres,
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
