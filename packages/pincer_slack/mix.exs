defmodule PincerSlack.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/manelsen/Pincer"

  def project do
    [
      app: :pincer_slack,
      version: @version,
      elixir: "~> 1.14",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: false,
      deps: deps(),
      description: description(),
      package: package(),
      name: "PincerSlack",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:pincer_ports, "~> 0.1"},
      {:pincer_shared, "~> 0.1"},
      {:slack_elixir, "~> 1.2"}
    ]
  end

  defp description do
    "Slack channel adapter for the Pincer AI agent framework"
  end

  defp package do
    [
      name: "pincer_slack",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "priv/pincer_plugin.yaml", "mix.exs", "README.md", "LICENSE"]
    ]
  end
end
