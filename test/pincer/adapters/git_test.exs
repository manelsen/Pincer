defmodule Pincer.Adapters.GitTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Git

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

    # Ensure we are NOT in a repo
    {_, code} =
      System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
        cd: root,
        stderr_to_stdout: true
      )

    assert code != 0, "Test folder #{root} should not be a git repository"

    case Git.ensure_branch("project/research-language-policy", cwd: root) do
      {:ok, result} ->
        assert result.status == :created,
               "Expected :created, got #{inspect(result.status)}. Repo path: #{result.repo_path}"

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
        flunk("Git.ensure_branch failed with reason: #{inspect(reason)}")
    end
  end

  @tag :tmp_dir
  test "reports tracked paths and changes with the actual filenames", %{tmp_dir: root} do
    assert {:error, :not_a_repository} = Git.files(root, :tracked)
    assert {_, 0} = git(root, ["init"])
    assert {:error, :git_failed} = Git.files(root, :changed)

    path = "notas á.md"
    File.write!(Path.join(root, path), "first")
    assert {_, 0} = git(root, ["add", "--", path])

    assert {_, 0} =
             git(root, [
               "-c",
               "user.name=Pincer",
               "-c",
               "user.email=test@example.invalid",
               "-c",
               "commit.gpgsign=false",
               "commit",
               "-m",
               "fixture"
             ])

    assert {:ok, [^path]} = Git.files(root, :tracked)
    assert {:ok, []} = Git.files(root, :changed)

    File.write!(Path.join(root, path), "second")
    assert {:ok, [^path]} = Git.files(root, :changed)
  end

  defp git(root, args), do: System.cmd("git", args, cd: root, stderr_to_stdout: true)
end
