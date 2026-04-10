defmodule PincerSlack.MixProject do
  use Mix.Project

  def project do
    [
      app: :pincer_slack,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: [
        {:pincer_ports, path: "../pincer_ports"},
        {:slack_elixir, "~> 1.2"}
      ],
      description: "Slack channel adapter for the Pincer AI agent framework",
      package: [name: "pincer_slack", licenses: ["MIT"], maintainers: ["Micelio"], links: %{"GitHub" => "https://github.com/manelsen/Pincer"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
