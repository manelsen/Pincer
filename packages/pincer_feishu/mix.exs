defmodule PincerFeishu.MixProject do
  use Mix.Project

  def project do
    [
      app: :pincer_feishu,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: [
        {:pincer_ports, path: "../pincer_ports"},
        {:jason, "~> 1.4"},
        {:req, "~> 0.5"}
      ],
      description: "Feishu (Lark) channel adapter for the Pincer AI agent framework",
      package: [name: "pincer_feishu", licenses: ["MIT"], maintainers: ["Micelio"], links: %{}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
