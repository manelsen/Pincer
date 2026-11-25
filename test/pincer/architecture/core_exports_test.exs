defmodule Pincer.Architecture.CoreExportsTest do
  use ExUnit.Case, async: false

  alias Boundary.Mix.CompilerState

  test "Core exports match external production consumers and host configuration" do
    {:ok, _pid} = CompilerState.start_link()

    compiled = compiled_consumers()
    configured = literal_consumers("config/**/*.exs")
    packages = literal_consumers("packages/*/lib/**/*.ex")

    assert Pincer.Core.StartupGuard in compiled
    assert Pincer.Core.Session.Adapter in configured

    consumers =
      (compiled ++ configured ++ packages)
      |> Enum.filter(&core_module?/1)
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(Application.spec(:pincer, :modules)))

    [%{opts: opts}] = Pincer.Core.__info__(:attributes)[Boundary]
    exports = MapSet.new(opts[:exports], &Module.concat(Pincer.Core, &1))

    differences = %{
      missing: MapSet.difference(consumers, exports) |> Enum.sort(),
      unused: MapSet.difference(exports, consumers) |> Enum.sort()
    }

    assert differences == %{missing: [], unused: []}
  end

  defp compiled_consumers do
    for %{file: file, from: from, to: to} <- CompilerState.references(),
        String.starts_with?(file, "lib/"),
        from != Pincer.Core,
        not core_module?(from),
        do: to
  end

  defp literal_consumers(pattern) do
    Enum.flat_map(Path.wildcard(pattern), fn path ->
      ast = path |> File.read!() |> Code.string_to_quoted!(file: path)

      {_ast, modules} =
        Macro.prewalk(ast, [], fn
          {:__aliases__, _, [:Pincer, :Core | [_ | _] = parts]} = node, acc ->
            {node, [Module.concat([Pincer.Core | parts]) | acc]}

          {:__aliases__, _, [:"Elixir", :Pincer, :Core | [_ | _] = parts]} = node, acc ->
            {node, [Module.concat([Pincer.Core | parts]) | acc]}

          node, acc ->
            {node, acc}
        end)

      modules
    end)
  end

  defp core_module?(module),
    do: String.starts_with?(Atom.to_string(module), "Elixir.Pincer.Core.")
end
