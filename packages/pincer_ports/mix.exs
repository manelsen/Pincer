defmodule PincerPorts.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/micelio/pincer_ports"

  def project do
    [
      app: :pincer_ports,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: false,
      deps: [],
      description: "Port behaviours and contracts for the Pincer AI agent framework",
      package: package(),
      name: "PincerPorts",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp package do
    [
      name: "pincer_ports",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
