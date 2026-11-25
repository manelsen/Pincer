defmodule Pincer.Architecture.PackageIsolationTest do
  use ExUnit.Case, async: true

  @host_namespaces ~w(Adapters Core Infra Mix Plugin Storage Telemetry Utils)a

  test "package sources do not reference host application modules" do
    assert find_in_sources(&host_reference?/1) == []
  end

  test "package compiler attributes contain no suppressions or function calls" do
    assert find_in_sources(&invalid_compile_attribute?/1) == []
  end

  test "all packages compile with warnings as errors" do
    projects = Path.wildcard("packages/*/mix.exs")
    assert projects != []

    without_strict_warnings =
      Enum.reject(projects, fn file ->
        file
        |> parse!()
        |> contains?(fn
          {:elixirc_options, opts} when is_list(opts) -> opts[:warnings_as_errors] == true
          _ -> false
        end)
      end)

    assert without_strict_warnings == []
  end

  test "Telegram declares its external parser, HTTP client, and Telegex's Plug dependency" do
    project = parse!("packages/pincer_telegram/mix.exs")

    for name <- [:earmark_parser, :req, :plug] do
      assert contains?(project, fn
               {^name, requirement} when is_binary(requirement) -> true
               {:{}, _, [^name, requirement, _opts]} when is_binary(requirement) -> true
               _ -> false
             end),
             "Telegram must declare #{name} for standalone builds"
    end
  end

  defp find_in_sources(predicate) do
    files = Path.wildcard("packages/*/lib/**/*.ex")
    assert files != []

    for file <- files,
        contains?(parse!(file), predicate),
        do: file
  end

  defp host_reference?({:__aliases__, _, [:"Elixir" | parts]}), do: host_alias?(parts)
  defp host_reference?({:__aliases__, _, parts}), do: host_alias?(parts)

  defp host_reference?({{:., _, [{:__aliases__, _, root}, :{}]}, _, modules})
       when root in [[:Pincer], [:"Elixir", :Pincer]] do
    Enum.any?(modules, fn
      {:__aliases__, _, [namespace | _]} -> namespace in @host_namespaces
      _ -> false
    end)
  end

  defp host_reference?(_node), do: false

  defp host_alias?([:Pincer, namespace | _]), do: namespace in @host_namespaces
  defp host_alias?(_parts), do: false

  defp invalid_compile_attribute?({:@, _, [{:compile, _, [value]}]}) do
    case value do
      {:no_warn_undefined, _} -> true
      _ -> not Macro.quoted_literal?(value)
    end
  end

  defp invalid_compile_attribute?(_node), do: false

  defp parse!(file), do: file |> File.read!() |> Code.string_to_quoted!(file: file)

  defp contains?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? -> {node, found? or predicate.(node)} end)

    found?
  end
end
