defmodule PincerWebhook.MixProject do
  use Mix.Project

  def project do
    [
      app: :pincer_webhook,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: [{:pincer_ports, path: "../pincer_ports"}],
      description: "HTTP webhook channel adapter for the Pincer AI agent framework",
      package: [name: "pincer_webhook", licenses: ["MIT"], maintainers: ["Micelio"], links: %{}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
