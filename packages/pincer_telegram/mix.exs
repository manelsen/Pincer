defmodule PincerTelegram.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/micelio/pincer_telegram"

  def project do
    [
      app: :pincer_telegram,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # Hex
      description: "Telegram channel adapter for Pincer AI agent framework",
      package: package(),
      name: "PincerTelegram",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:pincer_ports, "~> 0.1"},
      {:telegex, "~> 1.8"},
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp package do
    [
      name: "pincer_telegram",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md", "LICENSE"]
    ]
  end
end
