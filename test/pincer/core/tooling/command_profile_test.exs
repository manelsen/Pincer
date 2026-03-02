defmodule Pincer.Core.Tooling.CommandProfileTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Tooling.CommandProfile

  describe "detect_stacks/1" do
    test "detects elixir/node/rust/python from workspace artifacts" do
      with_temp_workspace(fn root ->
        touch(root, "mix.exs")
        touch(root, "package.json")
        touch(root, "Cargo.toml")
        touch(root, "pyproject.toml")

        stacks = CommandProfile.detect_stacks(workspace_root: root)

        assert MapSet.member?(stacks, :elixir)
        assert MapSet.member?(stacks, :node)
        assert MapSet.member?(stacks, :rust)
        assert MapSet.member?(stacks, :python)
      end)
    end

    test "returns empty set when no known artifacts are present" do
      with_temp_workspace(fn root ->
        assert MapSet.new() == CommandProfile.detect_stacks(workspace_root: root)
      end)
    end
  end

  describe "dynamic_command_prefixes/1" do
    test "returns command prefixes constrained to detected stack" do
      with_temp_workspace(fn root ->
        touch(root, "mix.exs")
        touch(root, "package.json")

        prefixes = CommandProfile.dynamic_command_prefixes(workspace_root: root)

        assert ["mix", "format"] in prefixes
        assert ["mix", "pincer.security_audit"] in prefixes
        assert ["mix", "pincer.doctor"] in prefixes
        assert ["npm", "test"] in prefixes

        refute ["cargo", "test"] in prefixes
      end)
    end

    test "adds npm run script commands from package.json" do
      with_temp_workspace(fn root ->
        write_json(root, "package.json", %{
          "name" => "fixture",
          "scripts" => %{
            "lint" => "eslint .",
            "test:ci" => "npm test"
          }
        })

        prefixes = CommandProfile.dynamic_command_prefixes(workspace_root: root)

        assert ["npm", "run", "lint"] in prefixes
        assert ["npm", "run", "test:ci"] in prefixes
      end)
    end

    test "adds yarn/pnpm/bun run script commands from package.json" do
      with_temp_workspace(fn root ->
        write_json(root, "package.json", %{
          "name" => "fixture",
          "scripts" => %{
            "dev" => "vite",
            "build" => "vite build"
          }
        })

        prefixes = CommandProfile.dynamic_command_prefixes(workspace_root: root)

        assert ["yarn", "run", "dev"] in prefixes
        assert ["pnpm", "run", "dev"] in prefixes
        assert ["bun", "run", "dev"] in prefixes
        assert ["yarn", "run", "build"] in prefixes
        assert ["pnpm", "run", "build"] in prefixes
        assert ["bun", "run", "build"] in prefixes
      end)
    end

    test "adds make target commands from Makefile" do
      with_temp_workspace(fn root ->
        write_file(
          root,
          "Makefile",
          """
          ci:
          \tmix test

          build:
          \tmix compile
          """
        )

        prefixes = CommandProfile.dynamic_command_prefixes(workspace_root: root)

        assert ["make", "ci"] in prefixes
        assert ["make", "build"] in prefixes
      end)
    end

    test "adds local shell script commands only from workspace root" do
      with_temp_workspace(fn root ->
        write_file(root, "deploy.sh", "#!/usr/bin/env bash\necho deploy\n")
        write_file(root, "bootstrap.bash", "#!/usr/bin/env bash\necho bootstrap\n")
        write_file(root, ".hidden.sh", "#!/usr/bin/env bash\necho hidden\n")
        write_file(root, "scripts/nested.sh", "#!/usr/bin/env bash\necho nested\n")

        prefixes = CommandProfile.dynamic_command_prefixes(workspace_root: root)

        assert ["./deploy.sh"] in prefixes
        assert ["./bootstrap.bash"] in prefixes
        refute ["./.hidden.sh"] in prefixes
        refute ["./nested.sh"] in prefixes
      end)
    end

    test "ignores malformed package.json scripts gracefully" do
      with_temp_workspace(fn root ->
        write_file(root, "package.json", "{ invalid json")

        prefixes = CommandProfile.dynamic_command_prefixes(workspace_root: root)

        refute Enum.any?(prefixes, &match?(["npm", "run", _], &1))
      end)
    end

    test "ignores malformed package.json script names for all script runners" do
      with_temp_workspace(fn root ->
        write_json(root, "package.json", %{
          "name" => "fixture",
          "scripts" => %{
            "ok:ci" => "npm test",
            "bad name" => "echo nope",
            "bad/path" => "echo nope"
          }
        })

        prefixes = CommandProfile.dynamic_command_prefixes(workspace_root: root)

        assert ["npm", "run", "ok:ci"] in prefixes
        assert ["yarn", "run", "ok:ci"] in prefixes
        assert ["pnpm", "run", "ok:ci"] in prefixes
        assert ["bun", "run", "ok:ci"] in prefixes

        refute ["npm", "run", "bad name"] in prefixes
        refute ["yarn", "run", "bad name"] in prefixes
        refute ["pnpm", "run", "bad name"] in prefixes
        refute ["bun", "run", "bad name"] in prefixes

        refute ["npm", "run", "bad/path"] in prefixes
        refute ["yarn", "run", "bad/path"] in prefixes
        refute ["pnpm", "run", "bad/path"] in prefixes
        refute ["bun", "run", "bad/path"] in prefixes
      end)
    end
  end

  defp with_temp_workspace(fun) do
    root = Path.join("trash", "command_profile_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    try do
      fun.(root)
    after
      File.rm_rf(root)
    end
  end

  defp touch(root, rel_path) do
    path = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# fixture\n")
  end

  defp write_json(root, rel_path, value) do
    write_file(root, rel_path, Jason.encode!(value))
  end

  defp write_file(root, rel_path, contents) do
    path = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
