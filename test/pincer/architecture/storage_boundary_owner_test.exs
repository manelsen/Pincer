defmodule Pincer.Architecture.StorageBoundaryOwnerTest do
  use ExUnit.Case, async: true

  @adapters_boundary_file "lib/pincer/adapters.ex"

  test "legacy lib/pincer/storage directory does not exist" do
    refute File.exists?("lib/pincer/storage")
  end

  test "no file in lib, config, or test references the legacy storage namespace" do
    legacy_namespace = "Pincer." <> "Storage"

    offenders =
      ["lib/**/*.{ex,exs}", "config/**/*.{ex,exs}", "test/**/*.{ex,exs}"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.sort()
      |> Enum.filter(fn file ->
        file |> File.read!() |> String.contains?(legacy_namespace)
      end)

    assert offenders == [],
           "Expected no files to reference #{legacy_namespace}, found: #{inspect(offenders)}"
  end

  test "lib/pincer/adapters.ex exports storage modules using relative aliases" do
    exports = boundary_exports(@adapters_boundary_file)
    exported_names = Enum.map(exports, &Macro.to_string/1)

    for expected <- ["Storage.SQLite", "Storage.Checkpoint", "Storage.MemoryHelpers"] do
      assert expected in exported_names,
             "Expected #{@adapters_boundary_file} to export #{expected}, got: #{inspect(exported_names)}"
    end

    Enum.each(exports, fn export_alias ->
      refute absolute_adapters_alias?(export_alias),
             "#{@adapters_boundary_file} must use relative aliases in exports, got: #{Macro.to_string(export_alias)}"
    end)
  end

  defp boundary_exports(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!(file: file)
    |> collect_boundary_exports()
  end

  defp collect_boundary_exports(ast) do
    {_ast, exports} =
      Macro.prewalk(ast, [], fn
        {:use, _, [{:__aliases__, _, [:Boundary]}, opts]} = node, acc when is_list(opts) ->
          {node, acc ++ Keyword.get(opts, :exports, [])}

        node, acc ->
          {node, acc}
      end)

    exports
  end

  defp absolute_adapters_alias?({:__aliases__, _, [:Pincer, :Adapters | _]}), do: true
  defp absolute_adapters_alias?(_), do: false
end
