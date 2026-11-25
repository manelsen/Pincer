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
  | `git`        | Only safe `status` / `log` |
  | `cat`        | No `..` or shell operators |
  | `head`       | No `..` or shell operators |
  | `tail`       | No `..` or shell operators |
  | `mix`        | Only `test` and `compile`  |
  | `du`         | Only with `-sh`            |
  | `find`       | Read-only flags only (`-delete`/`-exec*`/`-ok*`/`-fprint*`/`-fls` blocked) |

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
  alias Pincer.Core.WorkspaceGuard
  alias Pincer.Ports.Sandbox
  require Logger

  @type spec :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @type execute_result ::
          {:ok, String.t()} | {:error, {:approval_required, String.t()} | String.t()}

  @doc false
  @spec approved_command_allowed?(String.t(), keyword()) :: :ok | {:error, String.t()}
  def approved_command_allowed?(command, opts \\ []) do
    WorkspaceGuard.command_allowed?(command, opts)
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
    approval_granted = Map.get(context, "approval_granted", false)

    # 1. Truncate
    command =
      if is_binary(command) do
        String.slice(command, 0, WorkspaceGuard.max_command_length())
      else
        command
      end

    validation_opts = [
      workspace_restrict: workspace_restrict,
      workspace_root: workspace_root
    ]

    if approval_granted do
      # An approval only lifts the human decision, never the static safety
      # checks: the exact command the user saw is validated again here.
      case approved_command_allowed?(command, validation_opts) do
        :ok ->
          Logger.info("[SAFE-SHELL] Pre-approved command: #{command}")
          execute_in_sandbox(command, validation_opts)

        {:error, reason} ->
          Logger.warning("[SAFE-SHELL] Rejected approved command: #{command} (Reason: #{reason})")

          {:error, {:approval_required, command}}
      end
    else
      # 2. Parse and Validate via centralized WorkspaceGuard policy
      case WorkspaceGuard.validate_command(command, validation_opts) do
        {:ok, sanitized_command} ->
          Logger.info("[SAFE-SHELL] Safe command: #{sanitized_command}")
          execute_in_sandbox(sanitized_command, validation_opts)

        {:error, reason} ->
          audit_required(command, reason)
      end
    end
  end

  defp audit_required(command, reason) do
    Logger.warning("[SAFE-SHELL] AUDIT REQUIRED: #{command} (Reason: #{reason})")
    {:error, {:approval_required, command}}
  end

  defp execute_in_sandbox(command, opts) do
    restrict? = Keyword.get(opts, :workspace_restrict, false)
    workspace_root = Keyword.get(opts, :workspace_root)

    sandbox_opts =
      [restrict_to_workspace: restrict?]
      |> then(fn acc ->
        if is_binary(workspace_root) and workspace_root != "" do
          expanded = Path.expand(workspace_root)
          acc = Keyword.put(acc, :workspace_path, expanded)
          if restrict?, do: Keyword.put(acc, :cwd, expanded), else: acc
        else
          if restrict?, do: Keyword.put(acc, :cwd, File.cwd!()), else: acc
        end
      end)

    case Sandbox.run(command, sandbox_opts) do
      {:ok, %{output: output, exit_code: 0}} ->
        {:ok, output}

      {:ok, %{output: output, exit_code: code}} ->
        {:error, "Command failed (exit #{code}): #{output}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Shell execution failed: #{inspect(reason)}"}
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
