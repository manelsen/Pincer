defmodule Pincer.Core.ProjectGit do
  @moduledoc """
  Minimal Git adapter for project branch provisioning.

  The adapter creates project branches locally without checking them out, keeping
  runtime side-effects low for the current process.
  """

  @type branch_result ::
          {:ok, %{name: String.t(), status: :created | :existing, source_branch: String.t()}}
          | {:error, any()}

  @doc """
  Ensures a local branch exists.

  Returns metadata with status `:created` when branch is newly created, or
  `:existing` when it already exists.
  """
  @spec ensure_branch(String.t()) :: branch_result()
  def ensure_branch(branch_name) when is_binary(branch_name) do
    cwd = File.cwd!()

    with {:ok, source_branch} <- current_branch(cwd),
         {:ok, exists?} <- branch_exists?(cwd, branch_name),
         {:ok, status} <- maybe_create_branch(cwd, branch_name, exists?) do
      {:ok, %{name: branch_name, status: status, source_branch: source_branch}}
    end
  end

  def ensure_branch(_), do: {:error, :invalid_branch_name}

  defp current_branch(cwd) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: cwd, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output |> String.trim() |> fallback_branch()}

      {output, _code} ->
        {:error, {:git_unavailable, sanitize(output)}}
    end
  end

  defp branch_exists?(cwd, branch_name) do
    case System.cmd(
           "git",
           ["show-ref", "--verify", "--quiet", "refs/heads/#{branch_name}"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {_, 0} -> {:ok, true}
      {_, 1} -> {:ok, false}
      {output, _code} -> {:error, {:git_unavailable, sanitize(output)}}
    end
  end

  defp maybe_create_branch(_cwd, _branch_name, true), do: {:ok, :existing}

  defp maybe_create_branch(cwd, branch_name, false) do
    case System.cmd("git", ["branch", branch_name], cd: cwd, stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, :created}

      {output, _code} ->
        {:error, {:branch_create_failed, sanitize(output)}}
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
end
