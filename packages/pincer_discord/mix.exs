defmodule PincerDiscord.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/manelsen/Pincer"

  def project do
    [
      app: :pincer_discord,
      version: @version,
      elixir: "~> 1.14",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: false,
      deps: deps(),
      description: description(),
      package: package(),
      name: "PincerDiscord",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:pincer_ports, "~> 0.1"},
      {:pincer_shared, "~> 0.1"},
      {:nostrum, "~> 0.10", runtime: false},
      {:req, "~> 0.5"}
    ]
  end

  defp description do
    "Discord channel adapter for the Pincer AI agent framework"
  end

  defp package do
    [
      name: "pincer_discord",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "priv/pincer_plugin.yaml", "mix.exs", "README.md", "LICENSE"]
    ]
  end
end
