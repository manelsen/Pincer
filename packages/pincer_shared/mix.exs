defmodule PincerShared.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/manelsen/Pincer"

  def project do
    [
      app: :pincer_shared,
      version: @version,
      elixir: "~> 1.14",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: false,
      compilers: [:boundary] ++ Mix.compilers(),
      deps: [
        {:pincer_ports, "~> 0.1"},
        {:boundary, "~> 0.12", runtime: false}
      ],
      description:
        "Shared utilities for Pincer channel adapters (Inbound, ProjectBridge, SessionBridge, Text, TokenCache, WebhookVerifier)",
      package: package(),
      name: "PincerShared",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp package do
    [
      name: "pincer_shared",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md", "LICENSE"]
    ]
  end
end
