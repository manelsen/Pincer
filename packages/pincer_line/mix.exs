defmodule PincerLine.MixProject do
  use Mix.Project

  def project do
    [
      app: :pincer_line,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: [
        {:pincer_ports, path: "../pincer_ports"},
        {:jason, "~> 1.4"},
        {:req, "~> 0.5"}
      ],
      description: "LINE Messaging API channel adapter for the Pincer AI agent framework",
      package: [name: "pincer_line", licenses: ["MIT"], maintainers: ["Micelio"], links: %{"GitHub" => "https://github.com/manelsen/Pincer"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
