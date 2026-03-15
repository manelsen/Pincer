defmodule Pincer.Adapters.Tools.SafeShell do
  @moduledoc """
  A security-conscious shell command execution tool with strict command parsing and validation.

  SafeShell provides a controlled interface for executing shell commands, using
  a strict parser to validate commands against a whitelist. Unlike previous versions
  that used prefix matching, this version parses the command structure to prevent
  injection attacks.

  ## Security Model

  SafeShell implements a **defense-in-depth** approach:

  1. **Command Parsing**: Commands are tokenized to identify the executable and arguments.
  2. **Strict Whitelist**: Only specific executables with validated arguments are allowed.
  3. **Injection Prevention**: Shell operators (`;`, `|`, `&&`, `$()`, etc.) are explicitly blocked.
  4. **Audit Logging**: All command attempts are logged.
  5. **MCP Delegation**: Actual execution is delegated to the MCP server.

  ## Whitelisted Commands

  The following commands are considered safe only when arguments pass validation:

  | Command      | Restrictions               |
  |--------------|----------------------------|
  | `ls`         | No shell operators         |
  | `pwd`        | No arguments allowed       |
  | `git`        | Only `status` and `log`    |
  | `cat`        | No `..` or shell operators |
  | `head`       | No `..` or shell operators |
  | `tail`       | No `..` or shell operators |
  | `mix`        | Only `test` and `compile`  |
  | `du`         | Only with `-sh`            |
  | `find`       | No shell operators         |

  ## Security Considerations

  ### 🛡️ Protection Mechanism

  The parser splits commands by whitespace and inspects the tokens. It explicitly rejects:
  - Command chaining (`;`, `&&`, `||`)
  - Piping (`|`)
  - Redirection (`>`, `<`)
  - Command substitution (`$()`, `` ` ``)
  - Path traversal in file arguments (`..`)

  ### Examples

      # Safe command - executes immediately
      iex> Pincer.Adapters.Tools.SafeShell.execute(%{"command" => "ls -la"})
      {:ok, "total 48..."}

      # Blocked: Command Chaining
      iex> Pincer.Adapters.Tools.SafeShell.execute(%{"command" => "ls; cat /etc/passwd"})
      {:error, {:approval_required, "ls; cat /etc/passwd"}}

      # Blocked: Path Traversal
      iex> Pincer.Adapters.Tools.SafeShell.execute(%{"command" => "cat ../config.exs"})
      {:error, {:approval_required, "cat ../config.exs"}}
  """

  @behaviour Pincer.Ports.Tool
  alias Pincer.Core.Tooling.CommandProfile
  alias Pincer.Core.WorkspaceGuard
  require Logger

  @max_command_length 1024
  @dangerous_chars ~r/[;&|`$<>]/
  @multiline_or_line_continuation ~r/\\(?:\r\n|\n|\r)|[\r\n]/

  @type spec :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @type execute_result ::
          {:ok, String.t()} | {:error, {:approval_required, String.t()} | String.t()}

  @doc false
  @spec approved_command_allowed?(String.t(), keyword()) :: :ok | {:error, String.t()}
  def approved_command_allowed?(command, opts \\ [])

  def approved_command_allowed?(command, _opts) when not is_binary(command) do
    {:error, "Invalid command"}
  end

  def approved_command_allowed?(command, opts) do
    workspace_restrict = Keyword.get(opts, :workspace_restrict, true)

    if not workspace_restrict do
      :ok
    else
      workspace_root = opts |> Keyword.get(:workspace_root, File.cwd!()) |> Path.expand()
      command = String.slice(command, 0, @max_command_length)

      cond do
        String.match?(command, @multiline_or_line_continuation) ->
          {:error, "Detected multiline or line-continuation shell payload"}

        String.match?(command, @dangerous_chars) ->
          {:error, "Detected dangerous shell characters"}

        true ->
          case parse_and_validate(command,
                 workspace_restrict: true,
                 workspace_root: workspace_root
               ) do
            {:ok, _sanitized_command} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @impl true
  def spec do
    %{
      name: "safe_shell",
      description:
        "Executes shell commands safely. Commands outside the whitelist require manual approval.",
      parameters: %{
        type: "object",
        properties: %{
          command: %{
            type: "string",
            description: "The bash command to execute."
          }
        },
        required: ["command"]
      }
    }
  end

  @impl true
  def execute(%{"command" => command} = args, context \\ %{}) do
    workspace_restrict = restrict_to_workspace?(args)
    workspace_root = Map.get(context, "workspace_path") || workspace_root(args)

    # 1. Truncate
    command = String.slice(command, 0, @max_command_length)

    cond do
      String.match?(command, @multiline_or_line_continuation) ->
        audit_required(command, "Detected multiline or line-continuation shell payload")

      String.match?(command, @dangerous_chars) ->
        # 2. Check for dangerous characters globally
        audit_required(command, "Detected dangerous shell characters")

      true ->
        # 3. Parse and Validate
        case parse_and_validate(command,
               workspace_restrict: workspace_restrict,
               workspace_root: workspace_root
             ) do
          {:ok, sanitized_command} ->
            Logger.info("[SAFE-SHELL] Safe command: #{sanitized_command}")

            call_mcp(sanitized_command,
              workspace_restrict: workspace_restrict,
              workspace_root: workspace_root
            )

          {:error, reason} ->
            audit_required(command, reason)
        end
    end
  end

  defp parse_and_validate(command, opts) do
    tokens = String.split(command, ~r/\s+/, trim: true)

    case tokens do
      ["ls" | args] -> validate_generic_args("ls", args, opts)
      ["pwd"] -> {:ok, "pwd"}
      ["git", "status"] -> {:ok, "git status"}
      ["git", "log" | args] -> validate_generic_args("git log", args, opts)
      ["cat", path] -> validate_path_arg("cat", path, opts)
      ["head", path] -> validate_path_arg("head", path, opts)
      ["tail", path] -> validate_path_arg("tail", path, opts)
      ["du", "-sh"] -> {:ok, "du -sh"}
      ["du", "-sh", path] -> validate_path_arg("du -sh", path, opts)
      ["mix", "test"] -> {:ok, "mix test"}
      ["mix", "compile"] -> {:ok, "mix compile"}
      ["find" | args] -> validate_generic_args("find", args, opts)
      # Grep is too complex to validate easily
      ["grep" | _] -> {:error, "Grep requires approval"}
      _ -> validate_dynamic_command(tokens, opts)
    end
  end

  defp validate_dynamic_command(tokens, opts) do
    workspace_root = opts |> Keyword.get(:workspace_root, File.cwd!()) |> Path.expand()

    prefixes = CommandProfile.dynamic_command_prefixes(workspace_root: workspace_root)

    case matching_dynamic_prefix(tokens, prefixes) do
      nil ->
        {:error, "Command not in whitelist or invalid arguments"}

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
      if starts_with_tokens?(tokens, prefix) do
        {prefix, Enum.drop(tokens, length(prefix))}
      end
    end)
  end

  defp starts_with_tokens?(tokens, prefix) do
    Enum.take(tokens, length(prefix)) == prefix
  end

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
    workspace_restrict = Keyword.get(opts, :workspace_restrict, false)

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

    case WorkspaceGuard.confine_path(candidate,
           root: workspace_root,
           reject_parent_segments: true
         ) do
      {:ok, _safe_path} -> false
      {:error, _reason} -> true
    end
  end

  defp format_command(cmd, []), do: cmd
  defp format_command(cmd, args), do: "#{cmd} #{Enum.join(args, " ")}"

  defp audit_required(command, reason) do
    Logger.warning("[SAFE-SHELL] AUDIT REQUIRED: #{command} (Reason: #{reason})")
    {:error, {:approval_required, command}}
  end

  defp call_mcp(command, opts) do
    payload =
      if Keyword.get(opts, :workspace_restrict, false) do
        %{
          "command" => command,
          "cwd" => opts |> Keyword.get(:workspace_root, File.cwd!()) |> Path.expand()
        }
      else
        %{"command" => command}
      end

    case Pincer.Ports.ToolRegistry.execute_tool("run_command", payload) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, "Shell execution failed: #{inspect(reason)}"}
    end
  end

  defp restrict_to_workspace?(args) do
    case Map.get(args, "restrict_to_workspace") do
      value when is_boolean(value) ->
        value

      _ ->
        tools = Application.get_env(:pincer, :tools, %{})

        case read_config_value(tools, ["restrict_to_workspace", "restrictToWorkspace"]) do
          false -> false
          _ -> true
        end
    end
  end

  defp workspace_root(args) do
    case Map.get(args, "workspace_root") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> File.cwd!()
    end
  end

  defp read_config_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) ||
        Enum.find_value(map, fn
          {existing_key, value} when is_atom(existing_key) ->
            if Atom.to_string(existing_key) == key, do: value

          _ ->
            nil
        end)
    end)
  end

  defp read_config_value(_map, _keys), do: nil
end
