defmodule PincerWhatsApp.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/manelsen/Pincer"

  def project do
    [
      app: :pincer_whatsapp,
      version: @version,
      elixir: "~> 1.14",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: false,
      compilers: Mix.compilers() ++ [:whatsapp_bridge],
      deps: deps(),
      description: description(),
      package: package(),
      name: "PincerWhatsApp",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:pincer_ports, "~> 0.2"},
      {:pincer_shared, "~> 0.2"},
      {:jason, "~> 1.4"}
    ]
  end

  defp description do
    "WhatsApp channel adapter and Go whatsapp_bridge compiler for the Pincer AI agent framework"
  end

  defp package do
    [
      name: "pincer_whatsapp",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: [
        "lib",
        "priv/pincer_plugin.yaml",
        "priv/src/whatsapp_bridge/main.go",
        "priv/src/whatsapp_bridge/go.mod",
        "priv/src/whatsapp_bridge/go.sum",
        "mix.exs",
        "README.md",
        "LICENSE"
      ]
    ]
  end
end
