defmodule Pincer.PortsContractTest do
  use ExUnit.Case, async: true

  @retired_ports [
    {Pincer.Ports.UserMenu, "lib/pincer/ports/user_menu.ex", :UserMenu},
    {Pincer.Ports.Onboarding, "lib/pincer/ports/onboarding.ex", :Onboarding},
    {Pincer.Ports.CapabilityDiscovery, "lib/pincer/ports/capability_discovery.ex",
     :CapabilityDiscovery},
    {Pincer.Ports.MediaUnderstanding, "lib/pincer/ports/media_understanding.ex",
     :MediaUnderstanding}
  ]

  test "ux adapter module declares PincerPorts.UX behaviour" do
    behaviours = Pincer.Core.UX.Adapter.module_info(:attributes)[:behaviour] || []
    assert PincerPorts.UX in behaviours
  end

  test "unused local port contracts and files are removed" do
    for {module, path, _export_atom} <- @retired_ports do
      refute Code.ensure_loaded?(module),
             "Expected #{inspect(module)} not to exist"

      refute File.exists?(path),
             "Expected #{path} to be removed"
    end
  end

  test "unused local ports are not exported by Pincer.Ports" do
    exports =
      "lib/pincer/ports.ex"
      |> File.read!()
      |> Code.string_to_quoted!(file: "lib/pincer/ports.ex")
      |> collect_boundary_exports()

    for {_module, _path, export_atom} <- @retired_ports do
      refute export_atom in exports,
             "Expected #{inspect(export_atom)} not to be exported by lib/pincer/ports.ex"
    end
  end

  defp collect_boundary_exports(ast) do
    {_ast, exports} =
      Macro.prewalk(ast, [], fn
        {:use, _, [{:__aliases__, _, [:Boundary]}, opts]} = node, acc when is_list(opts) ->
          opts
          |> Keyword.get(:exports, [])
          |> Enum.map(fn
            {:__aliases__, _, [name]} -> name
            {:__aliases__, _, parts} -> Module.concat(parts)
            other -> other
          end)
          |> then(&{node, acc ++ &1})

        node, acc ->
          {node, acc}
      end)

    exports
  end
end
