defmodule Pincer.Architecture.AdapterPortDependenciesTest do
  use ExUnit.Case, async: true

  test "adapters have no direct references to channels or LLM implementations" do
    violations =
      for file <- Path.wildcard("lib/pincer/adapters/**/*.ex"),
          references_host_layer?(file),
          do: file

    assert violations == []
  end

  defp references_host_layer?(file) do
    {_ast, found?} =
      file
      |> File.read!()
      |> Code.string_to_quoted!(file: file)
      |> Macro.prewalk(false, fn
        {:__aliases__, _, [:Pincer, layer | _]} = node, _found?
        when layer in [:Channels, :LLM] ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end
end
