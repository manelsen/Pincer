defmodule Pincer.Architecture.OrphanNamespacesTest do
  use ExUnit.Case, async: true

  @owned_boundary_files [
    "lib/pincer/telemetry.ex",
    "lib/pincer/application.ex",
    "lib/pincer/cli.ex"
  ]

  @removed_orphan_files [
    "lib/pincer/ai/embeddings.ex",
    "lib/pincer/models.ex",
    "lib/pincer/connector.ex",
    "lib/pincer/telemetry/otel.ex",
    "lib/pincer/utils/json_logger_formatter.ex",
    "lib/pincer/dx/macros.ex"
  ]

  test "Telemetry, Application, and CLI declare explicit non-top-level boundaries" do
    Enum.each(@owned_boundary_files, fn file ->
      assert File.exists?(file), "Expected boundary owner file #{file} to exist"

      boundary_opts = extract_boundary_opts!(file)

      refute Keyword.get(boundary_opts, :top_level?, false),
             "#{file} must declare `use Boundary` without `top_level?: true`"
    end)
  end

  test "Telemetry boundary exports PromEx with no deps" do
    opts = extract_boundary_opts!("lib/pincer/telemetry.ex")
    assert Keyword.get(opts, :deps) == []
    assert [PromEx] == export_names(opts)
  end

  test "orphan dead modules and production DX macros are removed" do
    Enum.each(@removed_orphan_files, fn file ->
      refute File.exists?(file), "Expected orphan file #{file} to be removed"
    end)

    refute File.dir?("lib/pincer/ai"), "Expected empty lib/pincer/ai directory to be removed"
    refute File.dir?("lib/pincer/dx"), "Expected empty lib/pincer/dx directory to be removed"
  end

  test "Pincer.Core.Models.Registry is preserved" do
    assert File.exists?("lib/pincer/core/models/registry.ex")
  end

  test "DX macros live in test/support under Pincer.Test boundary" do
    assert File.exists?("test/support/dx_macros.ex")
    assert File.exists?("test/support/test_boundary.ex")
    assert File.exists?("test/pincer/test_support/dx_macros_test.exs")

    test_boundary_opts = extract_boundary_opts!("test/support/test_boundary.ex")
    assert Keyword.get(test_boundary_opts, :top_level?) == true
    assert Keyword.get(test_boundary_opts, :check) == [in: false, out: false]
  end

  defp extract_boundary_opts!(file) do
    ast =
      file
      |> File.read!()
      |> Code.string_to_quoted!(file: file)

    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:use, _, [{:__aliases__, _, [:Boundary]}]} = node, nil ->
          {node, []}

        {:use, _, [{:__aliases__, _, [:Boundary]}, opts]} = node, nil when is_list(opts) ->
          {node, opts}

        node, acc ->
          {node, acc}
      end)

    assert is_list(found), "Expected #{file} to declare `use Boundary`"
    found
  end

  defp export_names(opts) do
    opts
    |> Keyword.get(:exports, [])
    |> Enum.map(fn
      {:__aliases__, _, parts} -> Module.concat(parts)
      other -> other
    end)
  end
end
