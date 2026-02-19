defmodule Pincer.MixProject do
  use Mix.Project

  def project do
    [
      app: :pincer,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :hackney],
      mod: {Pincer.Application, []}
    ]
  end

  defp deps do
    [
      {:telegex, "~> 1.8"},
      {:finch, "~> 0.16"},
      {:multipart, "~> 0.4"},
      {:tesla, "~> 1.9"},
      {:hackney, "~> 1.20"},
      {:req, "~> 0.5.0"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.11"},
      {:ecto_sqlite3, "~> 0.15"},
      {:dotenvy, "~> 1.0"},
      {:yaml_elixir, "~> 2.11"},
      {:nx, "~> 0.7.3"},
      {:bumblebee, "~> 0.5.3"},
      {:exla, "~> 0.7.3"},
      {:rustler, "~> 0.30"}
    ]
  end
end
