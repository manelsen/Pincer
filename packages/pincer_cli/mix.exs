defmodule PincerCLI.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/micelio/pincer_cli"

  def project do
    [
      app: :pincer_cli,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: false,
      deps: deps(),
      description: "CLI channel adapter for the Pincer AI agent framework",
      package: package(),
      name: "PincerCLI",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:pincer_ports, "~> 0.1"}
    ]
  end

  defp package do
    [
      name: "pincer_cli",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md", "LICENSE"]
    ]
  end
end
