defmodule PincerDeepseek.MixProject do
  use Mix.Project

  def project do
    [
      app: :pincer_deepseek,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: [
        {:pincer_ports, "~> 0.1"},
        {:pincer_openai_compat, "~> 0.1"},
        {:req, "~> 0.5"},
        {:jason, "~> 1.4"}
      ],
      description: "DeepSeek LLM provider adapter for the Pincer AI agent framework",
      package: [
        name: "pincer_deepseek",
        licenses: ["MIT"],
        maintainers: ["Micelio"],
        links: %{"GitHub" => "https://github.com/manelsen/Pincer"},
        files: ["lib", "mix.exs", "README.md", "LICENSE"]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
