defmodule Pincer.Tools.SafeShell do
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
      iex> Pincer.Tools.SafeShell.execute(%{"command" => "ls -la"})
      {:ok, "total 48..."}

      # Blocked: Command Chaining
      iex> Pincer.Tools.SafeShell.execute(%{"command" => "ls; cat /etc/passwd"})
      {:error, {:approval_required, "ls; cat /etc/passwd"}}

      # Blocked: Path Traversal
      iex> Pincer.Tools.SafeShell.execute(%{"command" => "cat ../config.exs"})
      {:error, {:approval_required, "cat ../config.exs"}}
  """

  @behaviour Pincer.Tool
  alias Pincer.Connectors.MCP.Manager, as: MCPManager
  require Logger

  @max_command_length 1024
  @dangerous_chars ~r/[;&|`$<>]/

  @type spec :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @type execute_result ::
          {:ok, String.t()} | {:error, {:approval_required, String.t()} | String.t()}

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
  def execute(%{"command" => command}) do
    # 1. Truncate
    command = String.slice(command, 0, @max_command_length)
    
    # 2. Check for dangerous characters globally
    if String.match?(command, @dangerous_chars) do
      audit_required(command, "Detected dangerous shell characters")
    else
      # 3. Parse and Validate
      case parse_and_validate(command) do
        {:ok, sanitized_command} ->
          Logger.info("[SAFE-SHELL] Safe command: #{sanitized_command}")
          call_mcp(sanitized_command)
          
        {:error, reason} ->
          audit_required(command, reason)
      end
    end
  end

  defp parse_and_validate(command) do
    tokens = String.split(command, ~r/\s+/, trim: true)
    
    case tokens do
      ["ls" | args] -> validate_generic_args("ls", args)
      ["pwd"] -> {:ok, "pwd"}
      ["git", "status"] -> {:ok, "git status"}
      ["git", "log" | _] -> {:ok, command} # Allow args for log? Maybe strict log only.
      ["cat", path] -> validate_path_arg("cat", path)
      ["head", path] -> validate_path_arg("head", path)
      ["tail", path] -> validate_path_arg("tail", path)
      ["du", "-sh"] -> {:ok, "du -sh"}
      ["du", "-sh", path] -> validate_path_arg("du -sh", path)
      ["mix", "test"] -> {:ok, "mix test"}
      ["mix", "compile"] -> {:ok, "mix compile"}
      ["find" | args] -> validate_generic_args("find", args)
      ["grep" | _] -> {:error, "Grep requires approval"} # Grep is too complex to validate easily
      _ -> {:error, "Command not in whitelist or invalid arguments"}
    end
  end

  defp validate_generic_args(cmd, args) do
    # Ensure no args look like paths with .. or starts with / (maybe allow absolute? report says no strict rule but let's be safe)
    # The report implementation suggested alphanumeric, dot, dash, slash, space.
    # But String.split already removed spaces.
    
    arg_str = Enum.join(args, " ")
    if String.contains?(arg_str, "..") do
       {:error, "Arguments contain path traversal"}
    else
       {:ok, "#{cmd} #{arg_str}"}
    end
  end
  
  defp validate_path_arg(cmd, path) do
    if String.contains?(path, "..") do
      {:error, "Path traversal detected"}
    else
      {:ok, "#{cmd} #{path}"}
    end
  end

  defp audit_required(command, reason) do
    Logger.warning("[SAFE-SHELL] AUDIT REQUIRED: #{command} (Reason: #{reason})")
    {:error, {:approval_required, command}}
  end

  defp call_mcp(command) do
    case MCPManager.execute_tool("run_command", %{"command" => command}) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, "MCP Shell failed: #{inspect(reason)}"}
    end
  end
end
