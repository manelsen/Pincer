defmodule Pincer.Adapters.Tools.GitInspect do
  @moduledoc """
  Read-only Git inspection tool for repositories inside the workspace.

  This tool covers the most common repository inspection flows without forcing
  the agent to fall back to raw shell commands for every Git read operation.
  All paths are confined to the current workspace.
  """

  @behaviour Pincer.Ports.Tool

  alias Pincer.Core.WorkspaceGuard

  @max_log_limit 50

  @impl true
  def spec do
    %{
      name: "git_inspect",
      description: "Inspects a Git repository inside the workspace using read-only commands.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["status", "diff", "log", "branches"],
            description: "Read-only Git operation to perform."
          },
          repo_path: %{
            type: "string",
            description:
              "Repository path relative to workspace root. Defaults to current workspace."
          },
          target_path: %{
            type: "string",
            description: "Optional file path for the 'diff' action, relative to repo root."
          },
          limit: %{
            type: "integer",
            description: "Maximum number of commits for 'log' (default: 10, max: 50)."
          }
        },
        required: ["action"]
      }
    }
  end

  @impl true
  def execute(args, context \\ %{}) do
    workspace_root = Map.get(context, "workspace_path", File.cwd!())
    repo_path = Map.get(args, "repo_path", ".")

    with {:ok, safe_repo_path} <- confine_path(repo_path, workspace_root),
         :ok <- ensure_git_repo(safe_repo_path) do
      run_action(args, safe_repo_path, workspace_root)
    end
  end

  defp run_action(%{"action" => "status"}, repo_path, _workspace_root) do
    run_git(repo_path, ["status", "--short", "--branch"])
  end

  defp run_action(%{"action" => "branches"}, repo_path, _workspace_root) do
    run_git(repo_path, ["branch", "--list"])
  end

  defp run_action(%{"action" => "log"} = args, repo_path, _workspace_root) do
    limit =
      args
      |> Map.get("limit", 10)
      |> normalize_limit()

    run_git(repo_path, ["log", "--oneline", "-n", Integer.to_string(limit)])
  end

  defp run_action(%{"action" => "diff"} = args, repo_path, workspace_root) do
    with {:ok, target_args} <- diff_args(args, repo_path, workspace_root) do
      run_git(repo_path, target_args)
    end
  end

  defp run_action(%{"action" => action}, _repo_path, _workspace_root) when is_binary(action) do
    {:error, "Unsupported git_inspect action: #{action}"}
  end

  defp run_action(_args, _repo_path, _workspace_root),
    do: {:error, "Missing or invalid 'action'."}

  defp diff_args(%{"target_path" => target_path}, repo_path, _workspace_root)
       when is_binary(target_path) do
    with {:ok, safe_target} <- confine_path(target_path, repo_path) do
      relative_target = Path.relative_to(safe_target, repo_path)
      {:ok, ["diff", "--", relative_target]}
    end
  end

  defp diff_args(_args, _repo_path, _workspace_root), do: {:ok, ["diff"]}

  defp confine_path(path, root) do
    WorkspaceGuard.confine_path(path,
      root: root,
      reject_parent_segments: true
    )
  end

  defp ensure_git_repo(repo_path) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        if String.trim(output) == "true" do
          :ok
        else
          {:error, "Path is not a Git repository."}
        end

      {_output, _code} ->
        {:error, "Path is not a Git repository."}
    end
  end

  defp run_git(repo_path, args) do
    case System.cmd("git", args, cd: repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim_trailing(output)}

      {output, _code} ->
        {:error, sanitize_git_error(output)}
    end
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_log_limit)
  defp normalize_limit(_limit), do: 10

  defp sanitize_git_error(output) when is_binary(output) do
    output
    |> String.trim()
    |> case do
      "" -> "Git command failed."
      message -> message
    end
  end
end
