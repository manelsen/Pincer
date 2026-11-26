defmodule PincerWebhook.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/manelsen/Pincer"

  def project do
    [
      app: :pincer_webhook,
      version: @version,
      elixir: "~> 1.14",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: false,
      deps: deps(),
      description: description(),
      package: package(),
      name: "PincerWebhook",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      {:pincer_ports, "~> 0.2"},
      {:pincer_shared, "~> 0.2"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"}
    ]
  end

  defp description do
    "HTTP webhook channel adapter for the Pincer AI agent framework"
  end

  defp package do
    [
      name: "pincer_webhook",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "priv/pincer_plugin.yaml", "mix.exs", "README.md", "LICENSE"]
    ]
  end
end
