defmodule PincerQwen.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/manelsen/Pincer"

  def project do
    [
      app: :pincer_qwen,
      version: @version,
      elixir: "~> 1.14",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: false,
      deps: deps(),
      description: description(),
      package: package(),
      name: "PincerQwen",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:pincer_ports, "~> 0.1"},
      {:pincer_openai_compat, "~> 0.1"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end

  defp description do
    "Alibaba Cloud Qwen (DashScope) LLM provider adapter for the Pincer AI agent framework"
  end

  defp package do
    [
      name: "pincer_qwen",
      licenses: ["MIT"],
      maintainers: ["Micelio"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md", "LICENSE"]
    ]
  end
end
