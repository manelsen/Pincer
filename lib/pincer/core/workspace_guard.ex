defmodule Pincer.Core.WorkspaceGuard do
  @moduledoc """
  Domain-level security policy for paths and commands.
  Centralizes safety rules for the unified executor.
  """
  require Logger
  alias Pincer.Core.Tooling.CommandProfile

  @outside_workspace_error "Access denied: Path outside workspace"
  @max_command_length 1024
  @dangerous_chars ~r/[;&|`$<>]/
  @multiline_or_line_continuation ~r/\\(?:\r\n|\n|\r)|[\r\n]/

  # --- Path Confinement ---

  @spec confine_path(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def confine_path(path, opts \\ []) do
    if not is_binary(path) do
      {:error, "Invalid path"}
    else
      reject_parent_segments = Keyword.get(opts, :reject_parent_segments, true)
      root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()
      candidate = String.trim(path)

      cond do
        candidate == "" ->
          {:error, "Invalid path"}

        String.contains?(candidate, "\0") ->
          {:error, "Path contains null bytes"}

        reject_parent_segments and parent_segment?(candidate) ->
          {:error, "Path traversal (..) not allowed"}

        true ->
          full_path = Path.expand(candidate, root)

          with :ok <- ensure_inside_root(full_path, root),
               :ok <- ensure_symlink_chain_inside_root(full_path, root) do
            {:ok, full_path}
          else
            {:error, _reason} -> {:error, @outside_workspace_error}
          end
      end
    end
  end

  defp parent_segment?(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
    |> Enum.any?(&(&1 == ".."))
  end

  defp ensure_inside_root(path, root) do
    if path == root or String.starts_with?(path, root <> "/") do
      :ok
    else
      {:error, :outside_workspace}
    end
  end

  # Detects symlink escapes without relying on File.realpath/1 (not available on older Elixir).
  # It walks each existing segment and validates that resolved links remain under root.
  defp ensure_symlink_chain_inside_root(path, root) do
    relative = Path.relative_to(path, root)
    segments = String.split(relative, "/", trim: true)

    segments
    |> Enum.reduce_while(root, fn segment, current ->
      next = Path.join(current, segment)

      case File.read_link(next) do
        {:ok, link_target} ->
          resolved = resolve_link_target(next, link_target)

          case ensure_inside_root(resolved, root) do
            :ok -> {:cont, resolved}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, :enoent} ->
          # Non-existing leaf/segment: no symlink to validate beyond this point.
          {:halt, :ok}

        {:error, :einval} ->
          {:cont, next}

        {:error, _reason} ->
          {:cont, next}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _ -> :ok
    end
  end

  defp resolve_link_target(link_path, link_target) when is_binary(link_target) do
    case Path.type(link_target) do
      :absolute ->
        Path.expand(link_target)

      :relative ->
        Path.expand(link_target, Path.dirname(link_path))

      _ ->
        Path.expand(link_target)
    end
  end

  # --- Command Security Policy ---

  @spec command_allowed?(String.t(), keyword()) :: :ok | {:error, String.t()}
  def command_allowed?(command, opts \\ []) do
    if not is_binary(command) do
      {:error, "Invalid command"}
    else
      workspace_root = opts |> Keyword.get(:workspace_root, File.cwd!()) |> Path.expand()
      command = String.slice(command, 0, @max_command_length)

      cond do
        String.match?(command, @multiline_or_line_continuation) ->
          {:error, "Detected multiline or line-continuation shell payload"}

        String.match?(command, @dangerous_chars) ->
          {:error, "Detected dangerous shell characters"}

        true ->
          case validate_command_structure(command, workspace_root) do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  defp validate_command_structure(command, workspace_root) do
    tokens = String.split(command, ~r/\s+/, trim: true)

    case tokens do
      ["ls" | _] ->
        :ok

      ["pwd"] ->
        :ok

      ["git", "status"] ->
        :ok

      ["git", "log" | _] ->
        :ok

      ["cat", path] ->
        validate_workspace_path_arg(path, workspace_root)

      ["head", path] ->
        validate_workspace_path_arg(path, workspace_root)

      ["tail", path] ->
        validate_workspace_path_arg(path, workspace_root)

      ["mix", "test"] ->
        :ok

      ["mix", "compile"] ->
        :ok

      _ ->
        prefixes = CommandProfile.dynamic_command_prefixes(workspace_root: workspace_root)

        if Enum.any?(prefixes, fn prefix -> Enum.take(tokens, length(prefix)) == prefix end) do
          :ok
        else
          {:error, "Command not in whitelist"}
        end
    end
  end

  defp validate_workspace_path_arg(path, workspace_root) when is_binary(path) do
    case confine_path(path, root: workspace_root, reject_parent_segments: true) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_workspace_path_arg(_path, _workspace_root), do: {:error, "Invalid path"}
end
