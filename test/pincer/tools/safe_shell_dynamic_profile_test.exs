defmodule Pincer.Adapters.Tools.SafeShellDynamicProfileTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.SafeShell

  describe "dynamic stack profile integration" do
    test "allows npm test when node stack is detected" do
      with_temp_workspace(fn root ->
        touch(root, "package.json")

        assert :ok =
                 SafeShell.approved_command_allowed?("npm test",
                   workspace_root: root,
                   workspace_restrict: true
                 )
      end)
    end

    test "allows npm run script only when script exists in package.json" do
      with_temp_workspace(fn root ->
        write_file(
          root,
          "package.json",
          Jason.encode!(%{"name" => "fixture", "scripts" => %{"lint" => "eslint ."}})
        )

        assert :ok =
                 SafeShell.approved_command_allowed?("npm run lint",
                   workspace_root: root,
                   workspace_restrict: true
                 )

        assert {:error, _} =
                 SafeShell.approved_command_allowed?("npm run release",
                   workspace_root: root,
                   workspace_restrict: true
                 )
      end)
    end

    test "allows yarn/pnpm/bun run script only when script exists in package.json" do
      with_temp_workspace(fn root ->
        write_file(
          root,
          "package.json",
          Jason.encode!(%{"name" => "fixture", "scripts" => %{"dev" => "vite"}})
        )

        assert :ok =
                 SafeShell.approved_command_allowed?("yarn run dev",
                   workspace_root: root,
                   workspace_restrict: true
                 )

        assert :ok =
                 SafeShell.approved_command_allowed?("pnpm run dev",
                   workspace_root: root,
                   workspace_restrict: true
                 )

        assert :ok =
                 SafeShell.approved_command_allowed?("bun run dev",
                   workspace_root: root,
                   workspace_restrict: true
                 )

        assert {:error, _} =
                 SafeShell.approved_command_allowed?("yarn run release",
                   workspace_root: root,
                   workspace_restrict: true
                 )
      end)
    end

    test "allows make target only when target exists in Makefile" do
      with_temp_workspace(fn root ->
        write_file(
          root,
          "Makefile",
          """
          ci:
          \tmix test
          """
        )

        assert :ok =
                 SafeShell.approved_command_allowed?("make ci",
                   workspace_root: root,
                   workspace_restrict: true
                 )

        assert {:error, _} =
                 SafeShell.approved_command_allowed?("make release",
                   workspace_root: root,
                   workspace_restrict: true
                 )
      end)
    end

    test "allows root shell script only when script exists locally" do
      with_temp_workspace(fn root ->
        write_file(root, "deploy.sh", "#!/usr/bin/env bash\necho deploy\n")

        assert :ok =
                 SafeShell.approved_command_allowed?("./deploy.sh",
                   workspace_root: root,
                   workspace_restrict: true
                 )

        assert {:error, _} =
                 SafeShell.approved_command_allowed?("./missing.sh",
                   workspace_root: root,
                   workspace_restrict: true
                 )
      end)
    end

    test "denies npm test when node stack is not detected" do
      with_temp_workspace(fn root ->
        assert {:error, _} =
                 SafeShell.approved_command_allowed?("npm test",
                   workspace_root: root,
                   workspace_restrict: true
                 )
      end)
    end

    test "allows mix format when elixir stack is detected" do
      with_temp_workspace(fn root ->
        touch(root, "mix.exs")

        assert :ok =
                 SafeShell.approved_command_allowed?("mix format",
                   workspace_root: root,
                   workspace_restrict: true
                 )
      end)
    end

    test "blocks unsafe path args even for dynamic commands" do
      with_temp_workspace(fn root ->
        touch(root, "mix.exs")

        assert {:error, _} =
                 SafeShell.approved_command_allowed?("mix format /etc/passwd",
                   workspace_root: root,
                   workspace_restrict: true
                 )
      end)
    end
  end

  defp with_temp_workspace(fun) do
    root = Path.join("trash", "safe_shell_dynamic_test_#{System.unique_integer([:positive])}")
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
    File.write!(path, "{}\n")
  end

  defp write_file(root, rel_path, contents) do
    path = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
