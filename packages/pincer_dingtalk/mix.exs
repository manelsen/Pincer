defmodule PincerDingTalk.MixProject do
  use Mix.Project

  def project do
    [
      app: :pincer_dingtalk,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: [
        {:pincer_ports, "~> 0.1"},
        {:pincer_shared, "~> 0.1"},
        {:jason, "~> 1.4"},
        {:req, "~> 0.5"}
      ],
      description: "DingTalk channel adapter for the Pincer AI agent framework",
      package: [
        name: "pincer_dingtalk", licenses: ["MIT"], maintainers: ["Micelio"], links: %{"GitHub" => "https://github.com/manelsen/Pincer"},
        files: ["lib", "mix.exs", "README.md", "LICENSE"]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
