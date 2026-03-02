defmodule Pincer.Core.ProjectGitTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.ProjectGit

  setup do
    unless System.find_executable("git") do
      {:skip, "git not available in test environment"}
    else
      :ok
    end
  end

  test "bootstraps isolated repository when current workspace is not a git repo" do
    root =
      Path.join(
        System.tmp_dir!(),
        "pincer_project_git_fixture_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    File.cd!(root, fn ->
      assert {:ok, result} = ProjectGit.ensure_branch("project/research-language-policy")
      assert result.status == :created
      assert result.bootstrapped
      assert is_binary(result.repo_path)
      assert File.dir?(Path.join(result.repo_path, ".git"))

      {branch_out, 0} =
        System.cmd("git", ["symbolic-ref", "--short", "HEAD"],
          cd: result.repo_path,
          stderr_to_stdout: true
        )

      assert String.trim(branch_out) == "project/research-language-policy"
    end)
  end
end
