defmodule Pincer.Core.WorkspaceGuard do
  @moduledoc """
  Domain-level security policy for paths and commands.
  Centralizes safety rules for the unified executor.
  """

  alias Pincer.Core.Tooling.CommandProfile

  @outside_workspace_error "Access denied: Path outside workspace"
  @max_command_length 1024
  @dangerous_chars ~r/[;&|`$<>]/
  @multiline_or_line_continuation ~r/\\(?:\r\n|\n|\r)|[\r\n]/
  @forbidden_find_flags MapSet.new([
                          "-delete",
                          "-exec",
                          "-execdir",
                          "-ok",
                          "-okdir",
                          "-fprint",
                          "-fprint0",
                          "-fprintf",
                          "-fls"
                        ])
  @forbidden_git_log_flags MapSet.new(["--output", "--ext-diff", "--textconv"])

  # --- Path Confinement ---

  @spec confine_path(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def confine_path(path, opts \\ [])

  def confine_path(path, _opts) when not is_binary(path), do: {:error, "Invalid path"}

  def confine_path(path, opts) do
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

  @doc """
  Returns the maximum allowed length (in characters) for a validated shell command.
  """
  @spec max_command_length() :: pos_integer()
  def max_command_length, do: @max_command_length

  @doc """
  Validates and normalizes a shell command against the centralized static
  allowlist and workspace confinement rules.
  """
  @spec validate_command(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_command(command, opts \\ [])

  def validate_command(command, _opts) when not is_binary(command),
    do: {:error, "Invalid command"}

  def validate_command(command, opts) do
    workspace_restrict = Keyword.get(opts, :workspace_restrict, true)
    workspace_root = opts |> Keyword.get(:workspace_root, File.cwd!()) |> Path.expand()
    command = String.slice(command, 0, @max_command_length)

    cond do
      String.match?(command, @multiline_or_line_continuation) ->
        {:error, "Detected multiline or line-continuation shell payload"}

      String.match?(command, @dangerous_chars) ->
        {:error, "Detected dangerous shell characters"}

      true ->
        parse_and_validate(command,
          workspace_restrict: workspace_restrict,
          workspace_root: workspace_root
        )
    end
  end

  @doc """
  Checks whether a shell command is permitted under the centralized policy.
  """
  @spec command_allowed?(String.t(), keyword()) :: :ok | {:error, String.t()}
  def command_allowed?(command, opts \\ []) do
    case validate_command(command, opts) do
      {:ok, _sanitized_command} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_and_validate(command, opts) do
    tokens = String.split(command, ~r/\s+/, trim: true)

    case tokens do
      ["ls" | args] ->
        validate_generic_args("ls", args, opts)

      ["pwd"] ->
        {:ok, "pwd"}

      ["git", "status"] ->
        {:ok, "git status"}

      ["git", "log" | args] ->
        validate_flagged_args(
          "git log",
          args,
          @forbidden_git_log_flags,
          "Dangerous git log flag requires approval",
          opts
        )

      ["cat", path] ->
        validate_path_arg("cat", path, opts)

      ["head", path] ->
        validate_path_arg("head", path, opts)

      ["tail", path] ->
        validate_path_arg("tail", path, opts)

      ["du", "-sh"] ->
        {:ok, "du -sh"}

      ["du", "-sh", path] ->
        validate_path_arg("du -sh", path, opts)

      ["mix", "test"] ->
        {:ok, "mix test"}

      ["mix", "compile"] ->
        {:ok, "mix compile"}

      ["find" | args] ->
        validate_flagged_args(
          "find",
          args,
          @forbidden_find_flags,
          "Dangerous find flag requires approval",
          opts
        )

      # Grep is too complex to validate easily
      ["grep" | _] ->
        {:error, "Grep requires approval"}

      _ ->
        validate_dynamic_command(tokens, opts)
    end
  end

  defp validate_dynamic_command(tokens, opts) do
    workspace_root = opts |> Keyword.get(:workspace_root, File.cwd!()) |> Path.expand()
    prefixes = CommandProfile.dynamic_command_prefixes(workspace_root: workspace_root)

    case matching_dynamic_prefix(tokens, prefixes) do
      nil ->
        {:error, "Command not in whitelist"}

      {prefix, args} ->
        if Enum.any?(args, &unsafe_generic_arg?(&1, opts)) do
          {:error, "Arguments contain unsafe path patterns"}
        else
          {:ok, Enum.join(prefix ++ args, " ")}
        end
    end
  end

  defp matching_dynamic_prefix(tokens, prefixes) do
    prefixes
    |> Enum.sort_by(&length/1, :desc)
    |> Enum.find_value(fn prefix ->
      if Enum.take(tokens, length(prefix)) == prefix do
        {prefix, Enum.drop(tokens, length(prefix))}
      end
    end)
  end

  defp validate_flagged_args(cmd, args, forbidden_set, danger_reason, opts) do
    if Enum.any?(args, &forbidden_flag?(&1, forbidden_set)) do
      {:error, danger_reason}
    else
      validate_generic_args(cmd, args, opts)
    end
  end

  defp forbidden_flag?(arg, forbidden_set) when is_binary(arg) do
    flag_name =
      arg
      |> String.trim()
      |> String.downcase()
      |> String.split("=", parts: 2)
      |> hd()

    MapSet.member?(forbidden_set, flag_name)
  end

  defp forbidden_flag?(_, _forbidden_set), do: true

  defp validate_generic_args(cmd, args, opts) do
    if Enum.any?(args, &unsafe_generic_arg?(&1, opts)) do
      {:error, "Arguments contain unsafe path patterns"}
    else
      {:ok, format_command(cmd, args)}
    end
  end

  defp validate_path_arg(cmd, path, opts) do
    if unsafe_path_arg?(path, opts) do
      {:error, "Unsafe path argument"}
    else
      {:ok, "#{cmd} #{path}"}
    end
  end

  defp unsafe_generic_arg?(arg, opts) when is_binary(arg) do
    candidate = String.trim(arg)

    cond do
      candidate == "" ->
        true

      String.starts_with?(candidate, "-") ->
        false

      String.contains?(candidate, "=") ->
        [_key, value] = String.split(candidate, "=", parts: 2)
        unsafe_path_arg?(value, opts)

      true ->
        unsafe_path_arg?(candidate, opts)
    end
  end

  defp unsafe_generic_arg?(_, _opts), do: true

  defp unsafe_path_arg?(path, opts) when is_binary(path) do
    candidate = String.trim(path)
    workspace_restrict = Keyword.get(opts, :workspace_restrict, true)

    candidate == "" or
      String.contains?(candidate, "\0") or
      String.contains?(candidate, "..") or
      String.starts_with?(candidate, "/") or
      String.starts_with?(candidate, "~") or
      String.match?(candidate, ~r/^[A-Za-z]:[\\\/]/) or
      workspace_escape?(candidate, opts, workspace_restrict)
  end

  defp unsafe_path_arg?(_path, _opts), do: true

  defp workspace_escape?(_candidate, _opts, false), do: false

  defp workspace_escape?(candidate, opts, true) do
    workspace_root = opts |> Keyword.get(:workspace_root, File.cwd!()) |> Path.expand()

    case confine_path(candidate, root: workspace_root, reject_parent_segments: true) do
      {:ok, _safe_path} -> false
      {:error, _reason} -> true
    end
  end

  defp format_command(cmd, []), do: cmd
  defp format_command(cmd, args), do: "#{cmd} #{Enum.join(args, " ")}"
end
