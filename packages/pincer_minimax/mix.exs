defmodule PincerMinimax.MixProject do
  use Mix.Project

  def project do
    [
      app: :pincer_minimax,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: [
        {:pincer_ports, path: "../pincer_ports"},
        {:pincer_openai_compat, path: "../pincer_openai_compat"},
        {:req, "~> 0.5"},
        {:jason, "~> 1.4"}
      ],
      description: "MiniMax AI LLM provider adapter for the Pincer AI agent framework",
      package: [
        name: "pincer_minimax",
        licenses: ["MIT"],
        maintainers: ["Micelio"],
        links: %{}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
