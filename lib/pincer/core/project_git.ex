defmodule Pincer.Core.ProjectGit do
  @moduledoc """
  Minimal Git adapter for project branch provisioning.

  The adapter creates project branches locally without checking them out, keeping
  runtime side-effects low for the current process.
  """

  @type branch_result ::
          {:ok,
           %{
             name: String.t(),
             status: :created | :existing,
             source_branch: String.t(),
             repo_path: String.t(),
             bootstrapped: boolean()
           }}
          | {:error, any()}

  @doc """
  Ensures a local branch exists.

  Returns metadata with status `:created` when branch is newly created, or
  `:existing` when it already exists.
  """
  @spec ensure_branch(String.t()) :: branch_result()
  def ensure_branch(branch_name) when is_binary(branch_name) do
    cwd = File.cwd!()

    case current_branch(cwd) do
      {:ok, source_branch} ->
        ensure_branch_in_repo(cwd, branch_name, source_branch, false)

      {:error, {:not_a_repository, _detail}} ->
        bootstrap_branch_repository(cwd, branch_name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def ensure_branch(_), do: {:error, :invalid_branch_name}

  defp ensure_branch_in_repo(cwd, branch_name, source_branch, bootstrapped) do
    with {:ok, exists?} <- branch_exists?(cwd, branch_name),
         {:ok, status} <- maybe_create_branch(cwd, branch_name, exists?) do
      {:ok,
       %{
         name: branch_name,
         status: status,
         source_branch: source_branch,
         repo_path: cwd,
         bootstrapped: bootstrapped
       }}
    end
  end

  defp current_branch(cwd) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output |> String.trim() |> fallback_branch()}

      {output, _code} ->
        case System.cmd("git", ["symbolic-ref", "--short", "HEAD"],
               cd: cwd,
               stderr_to_stdout: true
             ) do
          {fallback_output, 0} ->
            {:ok, fallback_output |> String.trim() |> fallback_branch()}

          {_fallback_output, _fallback_code} ->
            {:error, classify_git_error(output)}
        end
    end
  end

  defp branch_exists?(cwd, branch_name) do
    case System.cmd(
           "git",
           ["show-ref", "--verify", "--quiet", "refs/heads/#{branch_name}"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        {:ok, true}

      {_, 1} ->
        case current_branch(cwd) do
          {:ok, ^branch_name} -> {:ok, true}
          _ -> {:ok, false}
        end

      {output, _code} ->
        {:error, classify_git_error(output)}
    end
  end

  defp maybe_create_branch(_cwd, _branch_name, true), do: {:ok, :existing}

  defp maybe_create_branch(cwd, branch_name, false) do
    case has_commits?(cwd) do
      true ->
        case System.cmd("git", ["branch", branch_name], cd: cwd, stderr_to_stdout: true) do
          {_, 0} ->
            {:ok, :created}

          {output, _code} ->
            {:error, {:branch_create_failed, sanitize(output)}}
        end

      false ->
        case System.cmd("git", ["checkout", "-b", branch_name], cd: cwd, stderr_to_stdout: true) do
          {_, 0} ->
            {:ok, :created}

          {output, _code} ->
            {:error, {:branch_create_failed, sanitize(output)}}
        end
    end
  end

  defp has_commits?(cwd) do
    case System.cmd("git", ["rev-parse", "--verify", "HEAD"], cd: cwd, stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp bootstrap_branch_repository(cwd, branch_name) do
    repo_path = Path.join(cwd, Path.join("projects", project_slug(branch_name)))

    with :ok <- File.mkdir_p(repo_path),
         :ok <- ensure_git_initialized(repo_path, branch_name),
         {:ok, source_branch} <- current_branch(repo_path),
         {:ok, exists?} <- branch_exists?(repo_path, branch_name),
         {:ok, status} <- maybe_create_branch(repo_path, branch_name, exists?) do
      {:ok,
       %{
         name: branch_name,
         status: status,
         source_branch: source_branch,
         repo_path: repo_path,
         bootstrapped: true
       }}
    end
  end

  defp ensure_git_initialized(repo_path, _branch_name) do
    if File.dir?(Path.join(repo_path, ".git")) do
      :ok
    else
      case System.cmd("git", ["init"], cd: repo_path, stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {output, _code} ->
          {:error, {:git_unavailable, sanitize(output)}}
      end
    end
  end

  defp project_slug(branch_name) do
    branch_name
    |> String.replace_prefix("project/", "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "project"
      slug -> slug
    end
  end

  defp fallback_branch(""), do: "unknown"
  defp fallback_branch(branch), do: branch

  defp sanitize(output) when is_binary(output) do
    output
    |> String.trim()
    |> case do
      "" -> "unknown git error"
      value -> value
    end
  end

  defp classify_git_error(output) do
    detail = sanitize(output)

    if String.contains?(String.downcase(detail), "not a git repository") do
      {:not_a_repository, detail}
    else
      {:git_unavailable, detail}
    end
  end
end
