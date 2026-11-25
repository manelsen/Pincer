defmodule Pincer.Architecture.BoundaryAliasChecksTest do
  use ExUnit.Case, async: true

  test "Pincer.Ports.Storage does not export like_prefix_patterns/1" do
    Code.ensure_loaded!(Pincer.Ports.Storage)
    refute function_exported?(Pincer.Ports.Storage, :like_prefix_patterns, 1)
  end

  test "Pincer.Adapters.Storage.SQLite exports like_prefix_patterns/1 and escapes LIKE wildcards" do
    Code.ensure_loaded!(Pincer.Adapters.Storage.SQLite)
    assert function_exported?(Pincer.Adapters.Storage.SQLite, :like_prefix_patterns, 1)

    assert Pincer.Adapters.Storage.SQLite.like_prefix_patterns(["tmp/", "a%b_c!"]) == [
             "tmp/%",
             "a!%b!_c!!%"
           ]

    assert Pincer.Adapters.Storage.SQLite.like_prefix_patterns(["", nil, "x!%_"]) == [
             "x!!!%!_%"
           ]
  end

  test "Pincer.Ports, Pincer.Utils, and Pincer.Infra enable check: [aliases: true]" do
    for {file, module_parts} <- [
          {"lib/pincer/ports.ex", [:Pincer, :Ports]},
          {"lib/pincer/utils.ex", [:Pincer, :Utils]},
          {"lib/pincer/infra.ex", [:Pincer, :Infra]}
        ] do
      opts = boundary_opts!(file, module_parts)

      assert opts |> Keyword.get(:check, []) |> Keyword.get(:aliases) == true,
             "Expected #{Enum.join(module_parts, ".")} in #{file} to declare check: [aliases: true]"
    end
  end

  defp boundary_opts!(file, expected_module_parts) do
    ast = file |> File.read!() |> Code.string_to_quoted!(file: file)

    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, ^expected_module_parts}, [do: body]]} = node, _acc ->
          {node, extract_boundary_opts(body)}

        node, acc ->
          {node, acc}
      end)

    assert is_list(found),
           "Expected #{Enum.join(expected_module_parts, ".")} in #{file} to declare `use Boundary, opts`"

    found
  end

  defp extract_boundary_opts(body) do
    {_ast, opts} =
      Macro.prewalk(body, nil, fn
        {:use, _, [{:__aliases__, _, [:Boundary]}, opts]} = node, _acc when is_list(opts) ->
          {node, opts}

        node, acc ->
          {node, acc}
      end)

    opts
  end
end
