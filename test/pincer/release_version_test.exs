defmodule Pincer.ReleaseVersionTest do
  @moduledoc """
  Verifies that the root application, all 25 subpackages, plugin manifests, and
  `CHANGELOG.md` are aligned on the `0.2.0` release version.
  """
  use ExUnit.Case, async: true

  @expected_version "0.2.0"
  @expected_package_count 25

  test "root mix.exs reports version 0.2.0" do
    assert Mix.Project.config()[:version] == @expected_version
  end

  test "all 25 packages/*/mix.exs declare @version 0.2.0 and ~> 0.2 sibling requirements" do
    projects = Path.wildcard("packages/*/mix.exs") |> Enum.sort()
    assert length(projects) == @expected_package_count

    for file <- projects do
      ast = file |> File.read!() |> Code.string_to_quoted!(file: file)

      {_ast, versions} =
        Macro.prewalk(ast, [], fn
          {:@, _, [{:version, _, [ver]}]} = node, acc -> {node, [ver | acc]}
          node, acc -> {node, acc}
        end)

      assert versions == [@expected_version],
             "Expected #{file} to declare @version #{inspect(@expected_version)}, got #{inspect(versions)}"

      {_ast, bad_sibling_reqs} =
        Macro.prewalk(ast, [], fn
          {app, req} = node, acc
          when app in [:pincer_ports, :pincer_shared, :pincer_openai_compat] ->
            if is_binary(req) and req != "~> 0.2" do
              {node, [{app, req} | acc]}
            else
              {node, acc}
            end

          node, acc ->
            {node, acc}
        end)

      assert bad_sibling_reqs == [],
             "Expected #{file} sibling pincer_* requirements to be \"~> 0.2\", got #{inspect(bad_sibling_reqs)}"
    end
  end

  test "plugin manifests declare version 0.2.0" do
    for file <-
          Path.wildcard("priv/plugins/*/pincer_plugin.yaml") ++
            Path.wildcard("packages/*/priv/pincer_plugin.yaml") do
      {:ok, manifest} = Pincer.Plugin.Manifest.from_file(file)

      assert manifest.version == @expected_version,
             "Expected #{file} to declare version #{@expected_version}"
    end
  end

  test "CHANGELOG.md includes a 0.2.0 release section" do
    changelog = File.read!("CHANGELOG.md")
    assert changelog =~ ~r/^## \[0\.2\.0\] - 2026-11-27/m
    legacy_storage_module = Enum.join(["Pincer", "Storage", "Adapters", "SQLite"], ".")
    refute changelog =~ legacy_storage_module
    assert changelog =~ "Pincer.Adapters.Storage.SQLite"

    for expected_entry <- [
          "Pincer.Core.Executor.Ctx",
          "PincerPorts.LLM.RawResponseLogger",
          "Pincer.Core.Introspection.Client",
          "docker-compose.hardened.yml",
          "Pincer.Adapters.Connectors.MCP.Manager",
          "docs/architecture/overview.md"
        ] do
      assert changelog =~ expected_entry
    end
  end

  test "scripts/hex_publish.sh covers all 25 packages in dependency order" do
    script = File.read!("scripts/hex_publish.sh")
    [_, block] = Regex.run(~r/PUBLISH_ORDER=\((.*?)\)/s, script)
    publish_order = String.split(block, ~r/\s+/, trim: true)

    package_dirs =
      Path.wildcard("packages/*")
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert length(publish_order) == @expected_package_count
    assert Enum.sort(publish_order) == package_dirs

    assert Enum.take(publish_order, 3) == [
             "pincer_ports",
             "pincer_shared",
             "pincer_openai_compat"
           ]
  end

  test "package READMEs and moduledocs reference ~> 0.2 instead of ~> 0.1" do
    offenders =
      (Path.wildcard("packages/*/README.md") ++ Path.wildcard("packages/*/lib/**/*.ex"))
      |> Enum.sort()
      |> Enum.filter(fn file ->
        content = File.read!(file)
        Regex.match?(~r/\{:pincer_[a-z0-9_]+,\s*"~>\s*0\.1"\}/, content)
      end)

    assert offenders == [],
           "Expected all package docs to reference ~> 0.2, found ~> 0.1 in: #{inspect(offenders)}"
  end
end
