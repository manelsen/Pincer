defmodule PincerZhipu.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/manelsen/Pincer"

  def project do
    [
      app: :pincer_zhipu,
      version: @version,
      elixir: "~> 1.14",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: false,
      deps: deps(),
      description: description(),
      package: package(),
      name: "PincerZhipu",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:pincer_ports, "~> 0.2"},
      {:pincer_openai_compat, "~> 0.2"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end

  defp description do
    "Z.AI (Zhipu GLM) LLM provider adapter for the Pincer AI agent framework"
  end

  defp package do
    [
      name: "pincer_zhipu",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md", "LICENSE"]
    ]
  end
end
