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
    unique_id = "#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "pincer_git_test_#{unique_id}")

    # Ensure absolute cleanup
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(root)

    File.cd!(root, fn ->
      # Ensure we are NOT in a repo
      {_, code} = System.cmd("git", ["rev-parse", "--is-inside-work-tree"], stderr_to_stdout: true)
      assert code != 0, "Test folder #{root} should not be a git repository"

      case ProjectGit.ensure_branch("project/research-language-policy") do
        {:ok, result} ->
          assert result.status == :created, "Expected :created, got #{inspect(result.status)}. Repo path: #{result.repo_path}"
          assert result.bootstrapped
          assert is_binary(result.repo_path)
          assert File.dir?(Path.join(result.repo_path, ".git"))

          {branch_out, 0} =
            System.cmd("git", ["symbolic-ref", "--short", "HEAD"],
              cd: result.repo_path,
              stderr_to_stdout: true
            )

          assert String.trim(branch_out) == "project/research-language-policy"

        {:error, reason} ->
          flunk("ProjectGit.ensure_branch failed with reason: #{inspect(reason)}")
      end
    end)
  end
end
