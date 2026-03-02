defmodule Pincer.Ports.Tool do
  @moduledoc """
  Behaviour for defining tools that Pincer agents can use.

  Tools are the capabilities that allow agents to interact with the world—
  reading files, executing commands, calling APIs, or dispatching sub-agents.
  Every tool implements this behaviour and becomes available to the Executor
  when it constructs the LLM's function calling interface.

  ## The Tool Contract

  A tool must implement two callbacks:

  1. `spec/0` - Returns the JSON Schema describing the tool's interface
  2. `execute/1` - Executes the tool with validated arguments

  ## Example: A Simple Calculator

      defmodule MyApp.Tools.Calculator do
        @behaviour Pincer.Ports.Tool

        @impl true
        def spec do
          %{
            name: "calculate",
            description: "Performs basic arithmetic operations",
            parameters: %{
              type: "object",
              properties: %{
                operation: %{
                  type: "string",
                  enum: ["add", "subtract", "multiply", "divide"],
                  description: "The operation to perform"
                },
                a: %{
                  type: "number",
                  description: "First operand"
                },
                b: %{
                  type: "number",
                  description: "Second operand"
                }
              },
              required: ["operation", "a", "b"]
            }
          }
        end

        @impl true
        def execute(%{"operation" => op, "a" => a, "b" => b}) do
          result = case op do
            "add" -> a + b
            "subtract" -> a - b
            "multiply" -> a * b
            "divide" -> 
              if b == 0, do: throw(:division_by_zero)
              a / b
          end
          {:ok, "Result: \#{result}"}
        end
      end

  ## Multi-Tool Modules

  A single module can expose multiple tools by returning a list of specs:

      @impl true
      def spec do
        [
          %{name: "tool_one", ...},
          %{name: "tool_two", ...}
        ]
      end

  This is useful for grouping related capabilities (e.g., all file operations
  in one module).

  ## Context Injection

  The Executor automatically injects context into tool arguments:

  - `session_id` - The current session identifier
  - `tool_name` - The name of the tool being called

  Your tool can access these for logging, permissions, or state management:

      def execute(%{"action" => action, "session_id" => session_id}) do
        Logger.info("[\#{session_id}] Executing: \#{action}")
        # ...
      end

  ## Approval Workflow

  Tools that perform dangerous operations (shell commands, file deletion)
  should return `{:error, {:approval_required, command}}` to pause execution
  and request user confirmation:

      def execute(%{"command" => cmd}) do
        if dangerous?(cmd) do
          {:error, {:approval_required, cmd}}
        else
          # Safe to execute
          {:ok, run_command(cmd)}
        end
      end

  The Executor handles the approval flow, broadcasting to subscribers and
  waiting for a response before proceeding.

  ## Error Handling

  Return `{:error, reason}` for recoverable errors. The error message will
  be passed back to the LLM, allowing it to reason about failures and retry
  with different parameters.

  ## Registration

  Native tools are registered in `Pincer.Core.Executor`:

      @native_tools [
        Pincer.Adapters.Tools.FileSystem,
        Pincer.Adapters.Tools.Config,
        # Add your tool here
      ]

  For dynamic registration, consider using MCP servers instead.

  ## See Also

  - `Pincer.Core.Executor` - How tools are invoked
  - `Pincer.Adapters.Tools.FileSystem` - Example implementation
  - `Pincer.Adapters.Tools.SafeShell` - Approval workflow example
  """

  @doc """
  Returns the tool specification in OpenAI function calling format.

  The specification must include:
  - `name` - Unique identifier for the tool (snake_case recommended)
  - `description` - Clear explanation of what the tool does
  - `parameters` - JSON Schema object defining expected arguments

  For multi-tool modules, return a list of specifications.

  ## Example

      @impl true
      def spec do
        %{
          name: "read_file",
          description: "Reads the contents of a file",
          parameters: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "Absolute or relative path to the file"
              }
            },
            required: ["path"]
          }
        }
      end

  """
  @callback spec() :: map() | [map()]

  @doc """
  Executes the tool with the given arguments.

  Arguments are parsed from JSON and passed as a map. The Executor handles
  JSON decoding, so you receive Elixir data structures.

  ## Return Values

  - `{:ok, result}` - Success. `result` should be a string (LLM reads it)
  - `{:error, {:approval_required, details}}` - Request user confirmation
  - `{:error, reason}` - Failure. `reason` will be shown to the LLM

  ## Example

      @impl true
      def execute(%{"path" => path}) do
        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, :enoent} -> {:error, "File not found: \#{path}"}
          {:error, reason} -> {:error, "Read error: \#{inspect(reason)}"}
        end
      end

  """
  @callback execute(args :: map()) :: {:ok, String.t()} | {:error, any()}
end
