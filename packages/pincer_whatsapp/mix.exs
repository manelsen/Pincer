defmodule PincerWhatsApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :pincer_whatsapp,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      compilers: Mix.compilers() ++ [:whatsapp_bridge],
      deps: [{:pincer_ports, "~> 0.1"}, {:jason, "~> 1.4"}],
      description:
        "WhatsApp channel adapter and Go whatsapp_bridge compiler for the Pincer AI agent framework",
      package: [
        name: "pincer_whatsapp",
        licenses: ["MIT"],
        maintainers: ["Micelio"],
        links: %{"GitHub" => "https://github.com/manelsen/Pincer"},
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
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
