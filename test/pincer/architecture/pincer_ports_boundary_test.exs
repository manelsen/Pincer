defmodule Pincer.Architecture.PincerPortsBoundaryTest do
  use ExUnit.Case, async: true

  @ports_mix "packages/pincer_ports/mix.exs"
  @ports_owner "packages/pincer_ports/lib/pincer_ports.ex"

  @expected_exports [
    "Structs.Usage",
    "Structs.IncomingMessage",
    "Session.Context",
    "LLM",
    "LLM.Provider",
    "LLM.RawResponseLogger",
    "Channel",
    "ChannelPolicy",
    "Project",
    "PubSub",
    "Session",
    "SkillsRegistry",
    "Streaming",
    "UX"
  ]

  test "pincer_ports mix.exs enables the :boundary compiler, dep, and warnings_as_errors" do
    project = project_pairs!(@ports_mix)

    assert project |> Keyword.fetch!(:compilers) |> Macro.to_string() =~ ":boundary"

    assert project |> Keyword.fetch!(:elixirc_options) |> Macro.to_string() =~
             "warnings_as_errors: true"

    assert project |> Keyword.fetch!(:deps) |> Macro.to_string() =~ "deps()"

    assert @ports_mix |> deps_body!() |> Macro.to_string() =~
             ~s({:boundary, "~> 0.12", runtime: false})
  end

  test "PincerPorts declares a Boundary with no deps and relative exports for all contracts" do
    opts = boundary_opts!(@ports_owner, [:PincerPorts])

    assert Keyword.get(opts, :deps) == []

    exported = opts |> Keyword.get(:exports, []) |> Enum.map(&Macro.to_string/1)
    assert Enum.sort(exported) == Enum.sort(@expected_exports)
  end

  test "packages/pincer_ports/lib defines only PincerPorts modules" do
    files = Path.wildcard("packages/pincer_ports/lib/**/*.ex")
    assert files != []

    offenders =
      for file <- files,
          {:defmodule, _, [{:__aliases__, _, [root | _]}, _]} <- top_level_modules(file),
          root != :PincerPorts do
        {file, root}
      end

    assert offenders == []

    refute File.dir?("packages/pincer_ports/lib/pincer"),
           "legacy packages/pincer_ports/lib/pincer directory must be removed"

    for rel <- ~w(
          structs/usage structs/incoming_message session/context llm llm/provider
          llm/raw_response_logger channel channel_policy project pubsub session skills_registry
          streaming ux
        ) do
      assert File.exists?("packages/pincer_ports/lib/pincer_ports/#{rel}.ex"),
             "missing packages/pincer_ports/lib/pincer_ports/#{rel}.ex"
    end
  end

  test "root Pincer and Pincer.Ports boundaries depend on PincerPorts" do
    for {file, parts} <- [
          {"lib/pincer.ex", [:Pincer]},
          {"lib/pincer/ports.ex", [:Pincer, :Ports]}
        ] do
      deps =
        file |> boundary_opts!(parts) |> Keyword.get(:deps, []) |> Enum.map(&Macro.to_string/1)

      assert "PincerPorts" in deps, "#{file} must declare PincerPorts in deps"
    end
  end

  test "package source and tests use the port for PubSub" do
    offenders =
      "packages/*/{lib,test}/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "Pincer.Infra.PubSub"))

    assert offenders == []
  end

  test "Pincer.Ports re-exports transition modules with relative aliases" do
    exports =
      "lib/pincer/ports.ex"
      |> boundary_opts!([:Pincer, :Ports])
      |> Keyword.get(:exports, [])
      |> Enum.map(&Macro.to_string/1)

    for expected <-
          ~w(Channel ChannelPolicy LLM Project PubSub Session SkillsRegistry Streaming UX) do
      assert expected in exports
    end
  end

  test "packages consume the shared LLM port without referencing the root facade" do
    offenders =
      for file <- Path.wildcard("packages/*/lib/**/*.ex"),
          String.contains?(File.read!(file), "Pincer.Ports.LLM"),
          do: file

    assert offenders == []
  end

  test "legacy root-namespace contract modules are no longer defined by pincer_ports" do
    for legacy <- [
          Pincer.Core.Structs.Usage,
          Pincer.Core.Structs.IncomingMessage,
          Pincer.Core.Session.Context,
          Pincer.LLM.Provider,
          Pincer.LLM.RawResponseLogger
        ] do
      refute Code.ensure_loaded?(legacy), "#{inspect(legacy)} must not exist after migration"
    end
  end

  defp read_ast!(file), do: file |> File.read!() |> Code.string_to_quoted!(file: file)

  defp top_level_modules(file) do
    {_ast, mods} =
      Macro.prewalk(read_ast!(file), [], fn
        {:defmodule, _, _} = node, acc -> {node, [node | acc]}
        node, acc -> {node, acc}
      end)

    mods
  end

  # Returns the keyword list literal returned by `def project`, unevaluated.
  defp project_pairs!(file) do
    {_ast, found} =
      Macro.prewalk(read_ast!(file), nil, fn
        {:def, _, [{:project, _, _}, [do: body]]} = node, nil -> {node, body}
        node, acc -> {node, acc}
      end)

    assert is_list(found), "Expected def project do [...] end in #{file}"
    found
  end

  defp deps_body!(file) do
    {_ast, found} =
      Macro.prewalk(read_ast!(file), nil, fn
        {:defp, _, [{:deps, _, _}, [do: body]]} = node, nil -> {node, body}
        node, acc -> {node, acc}
      end)

    assert found != nil, "Expected defp deps in #{file}"
    found
  end

  defp boundary_opts!(file, module_parts) do
    {_ast, found} =
      Macro.prewalk(read_ast!(file), nil, fn
        {:defmodule, _, [{:__aliases__, _, ^module_parts}, [do: body]]} = node, nil ->
          {node, extract_boundary_opts(body)}

        node, acc ->
          {node, acc}
      end)

    assert is_list(found), "Expected #{inspect(module_parts)} in #{file} to `use Boundary, opts`"
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
