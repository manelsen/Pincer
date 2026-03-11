defmodule Pincer.Adapters.Tools.GitInspectTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.GitInspect

  setup do
    unless System.find_executable("git") do
      {:skip, "git not available in test environment"}
    else
      root =
        Path.join(System.tmp_dir!(), "pincer_git_inspect_#{System.unique_integer([:positive])}")

      repo = Path.join(root, "repo")

      File.mkdir_p!(repo)

      System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)

      System.cmd("git", ["config", "user.email", "tests@pincer.local"],
        cd: repo,
        stderr_to_stdout: true
      )

      System.cmd("git", ["config", "user.name", "Pincer Tests"], cd: repo, stderr_to_stdout: true)

      File.write!(Path.join(repo, "notes.txt"), "alpha\n")
      System.cmd("git", ["add", "notes.txt"], cd: repo, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "first commit"], cd: repo, stderr_to_stdout: true)

      File.write!(Path.join(repo, "notes.txt"), "alpha\nbeta\n")
      System.cmd("git", ["checkout", "-b", "feature/demo"], cd: repo, stderr_to_stdout: true)
      File.write!(Path.join(repo, "readme.md"), "hello\n")
      System.cmd("git", ["add", "readme.md"], cd: repo, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "second commit"], cd: repo, stderr_to_stdout: true)

      File.write!(Path.join(repo, "notes.txt"), "alpha\nbeta\ngamma\n")

      on_exit(fn ->
        File.rm_rf!(root)
      end)

      {:ok, %{root: root, repo: repo, context: %{"workspace_path" => root}}}
    end
  end

  test "status returns current branch and modified file", %{context: context} do
    assert {:ok, output} =
             GitInspect.execute(%{"action" => "status", "repo_path" => "repo"}, context)

    assert output =~ "## feature/demo"
    assert output =~ "M notes.txt"
  end

  test "diff can scope to a target file", %{context: context} do
    assert {:ok, output} =
             GitInspect.execute(
               %{"action" => "diff", "repo_path" => "repo", "target_path" => "notes.txt"},
               context
             )

    assert output =~ "diff --git"
    assert output =~ "+gamma"
    refute output =~ "readme.md"
  end

  test "log respects limit", %{context: context} do
    assert {:ok, output} =
             GitInspect.execute(
               %{"action" => "log", "repo_path" => "repo", "limit" => 1},
               context
             )

    assert output =~ "second commit"
    refute output =~ "first commit"
  end

  test "branches lists local branches", %{context: context} do
    assert {:ok, output} =
             GitInspect.execute(%{"action" => "branches", "repo_path" => "repo"}, context)

    assert output =~ "feature/demo"
    assert output =~ "master" or output =~ "main"
  end

  test "rejects repo_path outside workspace", %{context: context} do
    assert {:error, message} =
             GitInspect.execute(
               %{"action" => "status", "repo_path" => "../../outside"},
               context
             )

    assert message =~ "Access denied" or message =~ "traversal"
  end
end
