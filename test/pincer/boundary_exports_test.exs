defmodule Pincer.BoundaryExportsTest do
  use ExUnit.Case, async: true

  @exporting_boundary_files [
    {"lib/pincer/core.ex", [:Pincer, :Core]},
    {"lib/pincer/core/ux.ex", [:Pincer, :Core, :UX]},
    {"lib/pincer/core/executor.ex", [:Pincer, :Core, :Executor]},
    {"lib/pincer/core/graph.ex", [:Pincer, :Core, :Graph]},
    {"lib/pincer/core/introspection.ex", [:Pincer, :Core, :Introspection]},
    {"lib/pincer/core/llm.ex", [:Pincer, :Core, :LLM]},
    {"lib/pincer/core/memory.ex", [:Pincer, :Core, :Memory]},
    {"lib/pincer/core/orchestration.ex", [:Pincer, :Core, :Orchestration]},
    {"lib/pincer/core/project.ex", [:Pincer, :Core, :Project]},
    {"lib/pincer/core/session.ex", [:Pincer, :Core, :Session]},
    {"lib/pincer/core/skills.ex", [:Pincer, :Core, :Skills]},
    {"lib/pincer/infra.ex", [:Pincer, :Infra]},
    {"lib/pincer/ports.ex", [:Pincer, :Ports]},
    {"lib/pincer/adapters.ex", [:Pincer, :Adapters]},
    {"lib/pincer/adapters/tools.ex", [:Pincer, :Adapters, :Tools]},
    {"lib/pincer/adapters/connectors.ex", [:Pincer, :Adapters, :Connectors]},
    {"lib/pincer/adapters/health.ex", [:Pincer, :Adapters, :Health]},
    {"lib/pincer/plugin.ex", [:Pincer, :Plugin]},
    {"lib/pincer/telemetry.ex", [:Pincer, :Telemetry]},
    {"lib/pincer/utils.ex", [:Pincer, :Utils]},
    {"packages/pincer_ports/lib/pincer_ports.ex", [:PincerPorts]},
    {"packages/pincer_shared/lib/pincer/channels/shared.ex", [:Pincer, :Channels, :Shared]}
  ]

  @non_exporting_boundary_files [
    {"lib/pincer/channels.ex", [:Pincer, :Channels]},
    {"lib/pincer/llm.ex", [:Pincer, :LLM]},
    {"lib/pincer/application.ex", [:Pincer, :Application]},
    {"lib/pincer/cli.ex", [:Pincer, :CLI]},
    {"lib/pincer/core/hook_dispatcher.ex", [:Pincer, :Core, :HookDispatcher]}
  ]

  test "owner boundary exports use relative aliases" do
    assert absolute_owner_alias?({:__aliases__, [], [:Pincer, :Core, :Session]}, [:Pincer, :Core])
    assert absolute_owner_alias?({:__aliases__, [], [:PincerPorts, :LLM]}, [:PincerPorts])
    refute absolute_owner_alias?({:__aliases__, [], [:Session, :Server]}, [:Pincer, :Core])

    Enum.each(@exporting_boundary_files, fn {file, owner_alias} ->
      exports = boundary_exports!(file, owner_alias)
      assert exports != [], "#{file} should declare exports for this regression test"

      Enum.each(exports, fn export_alias ->
        refute absolute_owner_alias?(export_alias, owner_alias),
               """
               #{file} exports #{Macro.to_string(export_alias)} with owner-prefixed alias.
               Use relative aliases inside `exports` for #{Enum.join(owner_alias, ".")}.
               """
      end)
    end)
  end

  test "all exporting boundary modules across lib and packages use relative aliases" do
    discovered =
      ["lib/**/*.ex", "packages/*/lib/**/*.ex"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.flat_map(&exporting_boundaries_in_file/1)

    assert discovered != []

    discovered_pairs =
      Enum.map(discovered, fn {file, module_parts, _exports} -> {file, module_parts} end)

    Enum.each(@exporting_boundary_files, fn expected ->
      assert expected in discovered_pairs,
             "Expected #{inspect(expected)} to be discovered as an exporting boundary"
    end)

    Enum.each(discovered, fn {file, owner_alias, exports} ->
      Enum.each(exports, fn export_alias ->
        refute absolute_owner_alias?(export_alias, owner_alias),
               """
               #{file} exports #{Macro.to_string(export_alias)} with owner-prefixed alias.
               Use relative aliases inside `exports` for #{Enum.join(owner_alias, ".")}.
               """
      end)
    end)
  end

  test "non-exporting boundary roots declare use Boundary with empty exports" do
    Enum.each(@non_exporting_boundary_files, fn {file, module_parts} ->
      opts = boundary_opts!(file, module_parts)

      refute Keyword.has_key?(opts, :classify_to),
             "#{file} should be a boundary root, not classified via :classify_to"

      refute Keyword.get(opts, :top_level?, false),
             "#{file} should not declare top_level?: true"

      assert Keyword.get(opts, :exports, []) == [],
             "#{file} should not export modules (expected exports: [])"
    end)
  end

  test "mix tasks are manually classified to Pincer.Mix boundary" do
    mix_boundary_source = File.read!("lib/pincer.ex")

    assert mix_boundary_source =~ "defmodule Pincer.Mix do"
    assert mix_boundary_source =~ "use Boundary"
    assert mix_boundary_source =~ "top_level?: true"
    assert mix_boundary_source =~ "check: [in: false, out: false]"

    task_files = Path.wildcard("lib/mix/tasks/*.ex") |> Enum.sort()
    assert length(task_files) >= 12

    Enum.each(task_files, fn file ->
      source = File.read!(file)

      assert mix_task_classified?(source),
             "#{file} must declare `use Boundary, classify_to: Pincer.Mix`"
    end)

    unclassified_task = """
    defmodule Mix.Tasks.Pincer.Unclassified do
      use Mix.Task
      def run(_args), do: :ok
    end
    """

    wrong_boundary_task = """
    defmodule Mix.Tasks.Pincer.WrongBoundary do
      use Boundary, classify_to: Pincer.Core
      use Mix.Task
    end
    """

    refute mix_task_classified?(unclassified_task)
    refute mix_task_classified?(wrong_boundary_task)
  end

  test "web decoder module is namespaced inside adapters boundary" do
    source = File.read!("lib/pincer/adapters/tools/web.ex")

    assert source =~ "defmodule Pincer.Adapters.Tools.Web.HtmlEntities do"
    refute source =~ "defmodule HtmlEntities do"
  end

  test "retired media contracts are absent" do
    refute Code.ensure_loaded?(Pincer.Ports.MediaUnderstanding)
    refute Code.ensure_loaded?(Pincer.Adapters.MediaDispatcher)
  end

  test "core modules do not depend directly on concrete adapters" do
    core_files = Path.wildcard("lib/pincer/core/**/*.ex")
    assert core_files != []

    Enum.each(core_files, fn file ->
      source = File.read!(file)

      refute source =~ "Pincer.Adapters",
             "#{file} should route adapter calls through a port"
    end)
  end

  defp boundary_exports!(file, expected_module_parts) do
    file
    |> boundary_opts!(expected_module_parts)
    |> Keyword.get(:exports, [])
  end

  defp boundary_opts!(file, expected_module_parts) do
    ast = file |> File.read!() |> Code.string_to_quoted!(file: file)

    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, ^expected_module_parts}, [do: body]]} = node, nil ->
          {node, extract_boundary_opts(body)}

        node, acc ->
          {node, acc}
      end)

    assert is_list(found),
           "Expected #{Enum.join(expected_module_parts, ".")} in #{file} to declare `use Boundary`"

    found
  end

  defp exporting_boundaries_in_file(file) do
    ast = file |> File.read!() |> Code.string_to_quoted!(file: file)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, module_parts}, [do: body]]} = node, acc ->
          case extract_boundary_opts(body) do
            opts when is_list(opts) ->
              case Keyword.get(opts, :exports, []) do
                [_ | _] = exports -> {node, [{file, module_parts, exports} | acc]}
                _ -> {node, acc}
              end

            nil ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp extract_boundary_opts(body) do
    {_ast, opts} =
      Macro.prewalk(body, nil, fn
        {:use, _, [{:__aliases__, _, [:Boundary]}]} = node, nil ->
          {node, []}

        {:use, _, [{:__aliases__, _, [:Boundary]}, opts]} = node, nil when is_list(opts) ->
          {node, opts}

        node, acc ->
          {node, acc}
      end)

    opts
  end

  defp mix_task_classified?(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        {_ast, found?} =
          Macro.prewalk(ast, false, fn
            {:use, _, [{:__aliases__, _, [:Boundary]}, opts]} = node, acc when is_list(opts) ->
              classified? =
                match?({:__aliases__, _, [:Pincer, :Mix]}, Keyword.get(opts, :classify_to))

              {node, acc or classified?}

            node, acc ->
              {node, acc}
          end)

        found?

      _ ->
        false
    end
  end

  defp absolute_owner_alias?({:__aliases__, _, [:"Elixir" | parts]}, owner_parts) do
    Enum.take(parts, length(owner_parts)) == owner_parts
  end

  defp absolute_owner_alias?({:__aliases__, _, parts}, owner_parts) do
    Enum.take(parts, length(owner_parts)) == owner_parts
  end

  defp absolute_owner_alias?(_, _), do: false
end
