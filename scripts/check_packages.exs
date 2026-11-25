defmodule PincerPackageCheck do
  @moduledoc """
  Builds packages as separate Mix projects with local sibling dependencies.

  Each project uses its own temporary build and dependency directories.
  The repository lockfile pins external dependencies to the versions used
  by the monorepo.
  """

  @doc "Checks the named packages, or all packages when the list is empty."
  def run(requested) do
    root = Path.expand("..", __DIR__)
    projects = Path.wildcard(Path.join(root, "packages/*/mix.exs"))
    packages = Map.new(projects, fn file -> {Path.basename(Path.dirname(file)), file} end)
    selected = if requested == [], do: Map.keys(packages) |> Enum.sort(), else: requested

    stage =
      Path.join(
        System.tmp_dir!(),
        "pincer-package-check-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(stage)

    try do
      Enum.each(packages, fn {name, project} ->
        stage_package(Path.dirname(project), Path.join(stage, name), root, packages)
      end)

      Enum.each(selected, fn name ->
        Map.fetch!(packages, name)
        verify(name, Path.join(stage, name))
      end)

      IO.puts("Verified #{length(selected)} isolated package(s).")
    after
      File.rm_rf!(stage)
    end
  end

  defp stage_package(source, destination, root, packages) do
    File.mkdir!(destination)

    for entry <- File.ls!(source) -- ~w(_build deps mix.exs mix.lock) do
      File.cp_r!(Path.join(source, entry), Path.join(destination, entry))
    end

    project =
      source
      |> Path.join("mix.exs")
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk(&use_local_dependency(&1, packages))
      |> Macro.to_string()

    File.write!(Path.join(destination, "mix.exs"), project <> "\n")
    File.cp!(Path.join(root, "mix.lock"), Path.join(destination, "mix.lock"))
  end

  defp use_local_dependency({app, requirement} = dependency, packages)
       when is_atom(app) and is_binary(requirement) do
    name = Atom.to_string(app)

    if Map.has_key?(packages, name) do
      {:{}, [], [app, requirement, [path: "../#{name}"]]}
    else
      dependency
    end
  end

  defp use_local_dependency(node, _packages), do: node

  defp verify(name, directory) do
    IO.puts("\nChecking #{name}")
    tests? = File.exists?(Path.join(directory, "test/test_helper.exs"))

    env = [
      {"MIX_ENV", if(tests?, do: "test", else: "prod")},
      {"MIX_BUILD_PATH", nil},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_DEPS_PATH", nil},
      {"MIX_EXS", nil}
    ]

    mix!(directory, env, ~w(deps.get))

    # Telegex uses Plug.Router even though its Plug dependency is optional.
    if name == "pincer_telegram" do
      mix!(directory, env, ~w(deps.compile mime plug_crypto telemetry plug))
    end

    mix!(directory, env, ~w(compile --warnings-as-errors))
    if tests?, do: mix!(directory, env, ~w(test --warnings-as-errors))
  end

  defp mix!(directory, env, args) do
    {_, status} =
      System.cmd("mix", args, cd: directory, env: env, into: IO.stream(:stdio, :line))

    if status != 0 do
      raise "#{Path.basename(directory)}: mix #{Enum.join(args, " ")} exited with #{status}"
    end
  end
end

PincerPackageCheck.run(System.argv())
