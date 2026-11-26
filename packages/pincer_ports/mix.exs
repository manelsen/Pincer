defmodule PincerPorts.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/manelsen/Pincer"

  def project do
    [
      app: :pincer_ports,
      version: @version,
      elixir: "~> 1.14",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: false,
      compilers: [:boundary] ++ Mix.compilers(),
      deps: deps(),
      description: description(),
      package: package(),
      name: "PincerPorts",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:boundary, "~> 0.12", runtime: false}
    ]
  end

  defp description do
    "Port behaviours and contracts for the Pincer AI agent framework"
  end

  defp package do
    [
      name: "pincer_ports",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md", "LICENSE"]
    ]
  end
end
