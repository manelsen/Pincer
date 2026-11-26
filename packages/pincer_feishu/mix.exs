defmodule PincerFeishu.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/manelsen/Pincer"

  def project do
    [
      app: :pincer_feishu,
      version: @version,
      elixir: "~> 1.14",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: false,
      deps: deps(),
      description: description(),
      package: package(),
      name: "PincerFeishu",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:pincer_ports, "~> 0.1"},
      {:pincer_shared, "~> 0.1"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"}
    ]
  end

  defp description do
    "Feishu (Lark) channel adapter for the Pincer AI agent framework"
  end

  defp package do
    [
      name: "pincer_feishu",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "priv/pincer_plugin.yaml", "mix.exs", "README.md", "LICENSE"]
    ]
  end
end
