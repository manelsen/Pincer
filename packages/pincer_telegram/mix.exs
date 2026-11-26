defmodule PincerTelegram.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/manelsen/Pincer"

  def project do
    [
      app: :pincer_telegram,
      version: @version,
      elixir: "~> 1.14",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "PincerTelegram",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:pincer_ports, "~> 0.2"},
      {:pincer_shared, "~> 0.2"},
      {:telegex, "~> 1.8"},
      {:plug, "~> 1.15"},
      {:earmark_parser, "~> 1.4"},
      {:req, "~> 0.7"},
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp description do
    "Telegram channel adapter for Pincer AI agent framework"
  end

  defp package do
    [
      name: "pincer_telegram",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "priv/pincer_plugin.yaml", "mix.exs", "README.md", "LICENSE"]
    ]
  end
end
