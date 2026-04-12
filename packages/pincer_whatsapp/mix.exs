defmodule PincerWhatsApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :pincer_whatsapp,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      compilers: [:whatsapp_bridge | Mix.compilers()],
      deps: [{:pincer_ports, "~> 0.1"}, {:jason, "~> 1.4"}],
      description: "WhatsApp Business API channel adapter for the Pincer AI agent framework",
      package: [
        name: "pincer_whatsapp", licenses: ["MIT"], maintainers: ["Micelio"], links: %{"GitHub" => "https://github.com/manelsen/Pincer"},
        files: ["lib", "mix.exs", "README.md", "LICENSE"]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
