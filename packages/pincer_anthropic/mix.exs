defmodule PincerAnthropic.MixProject do
  use Mix.Project

  def project do
    [
      app: :pincer_anthropic,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: [
        {:pincer_ports, path: "../pincer_ports"},
        {:req, "~> 0.5"},
        {:jason, "~> 1.4"}
      ],
      description: "Anthropic (Claude) LLM provider adapter for the Pincer AI agent framework",
      package: [
        name: "pincer_anthropic",
        licenses: ["MIT"],
        maintainers: ["Micelio"],
        links: %{"GitHub" => "https://github.com/manelsen/Pincer"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
