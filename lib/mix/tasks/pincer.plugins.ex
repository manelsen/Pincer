defmodule Mix.Tasks.Pincer.Plugins do
  @moduledoc """
  Gerencia plugins do Pincer.

  ## Subcomandos

      mix pincer.plugins list            # Lista plugins instalados
  """

  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  alias Pincer.Plugin.Manifest

  @shortdoc "Gerencia plugins do Pincer (list)"

  @impl Mix.Task
  def run(["list" | _rest]) do
    Application.ensure_all_started(:yaml_elixir)
    manifests = Manifest.discover()

    if manifests == [] do
      Mix.shell().info("Nenhum plugin encontrado.")
    else
      Mix.shell().info("Plugins instalados:\n")
      Enum.each(manifests, &print_manifest/1)
    end
  end

  def run(_args) do
    Mix.shell().info("""
    Usage:
      mix pincer.plugins list       # Lista plugins instalados
    """)
  end

  defp print_manifest(%Manifest{} = m) do
    Mix.shell().info("  #{m.id}  (#{m.kind})  v#{m.version}  — #{m.name}")

    if m.description do
      Mix.shell().info("    #{m.description}")
    end

    Mix.shell().info("")
  end
end
