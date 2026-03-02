defmodule Pincer.Adapters.Connectors.MCP.Client do
  @moduledoc """
  JSON-RPC client for MCP (Model Context Protocol) servers.

  This module implements the client-side of the MCP protocol, handling:
  - Protocol handshake (initialize/initialized)
  - Tool discovery via `tools/list`
  - Tool execution via `tools/call`
  - Request/response correlation using JSON-RPC 2.0 IDs

  ## What is MCP?

  MCP (Model Context Protocol) is an open protocol that standardizes how AI
  assistants interact with external tools, resources, and prompts. It enables:

  - **Tool Discovery**: Dynamically list available tools and their schemas
  - **Tool Execution**: Call tools with structured arguments
  - **Resource Access**: Read files, databases, or other data sources
  - **Prompt Templates**: Access predefined prompt templates

  ## Architecture

      ┌──────────────────────────────────────────────────────────────┐
      │                        MCP Client                            │
      ├──────────────────────────────────────────────────────────────┤
      │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐   │
      │  │  Transport  │  │ JSON-RPC    │  │ Request Correlation │   │
      │  │  (Stdio)    │  │ Encoding    │  │ (by ID)             │   │
      │  └─────────────┘  └─────────────┘  └─────────────────────┘   │
      └──────────────────────────────────────────────────────────────┘
                                │
                                ▼
                        ┌──────────────┐
                        │  MCP Server  │
                        │  (external)  │
                        └──────────────┘

  ## Protocol Handshake

  MCP requires an initialization handshake before tool operations:

      1. Client sends: `initialize` with protocol version and capabilities
      2. Server responds: Server capabilities and info
      3. Client sends: `notifications/initialized`
      4. Connection ready for tool operations

  This handshake happens automatically when starting the client.

  ## Usage

  Start a client connected to an MCP server:

      {:ok, pid} = Pincer.Adapters.Connectors.MCP.Client.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"],
        transport: Pincer.Adapters.Connectors.MCP.Transports.Stdio
      )

  List available tools:

      {:ok, response} = Pincer.Adapters.Connectors.MCP.Client.list_tools(pid)
      # => %{"result" => %{"tools" => [%{"name" => "read_file", ...}]}}

  Execute a tool:

      {:ok, result} = Pincer.Adapters.Connectors.MCP.Client.call_tool(pid, "read_file", %{
        "path" => "/home/user/example.txt"
      })

  ## Transport Abstraction

  The client uses a pluggable transport layer (see `Pincer.Adapters.Connectors.MCP.Transport`).
  By default, it uses `Stdio` transport which spawns the MCP server as a subprocess.

  ## Timeout Handling

  - `list_tools/1` - 30 second timeout
  - `call_tool/3` - 60 second timeout (tool execution may be slow)

  ## See Also

  - `Pincer.Adapters.Connectors.MCP.Manager` - Manages multiple clients
  - `Pincer.Adapters.Connectors.MCP.Transport` - Transport behaviour
  - `Pincer.Adapters.Connectors.MCP.Transports.Stdio` - Default transport
  """

  use GenServer
  require Logger
  alias Pincer.Adapters.Connectors.MCP.Transports.Stdio

  @type t :: %__MODULE__{
          transport: module(),
          transport_state: any(),
          requests: %{pos_integer() => GenServer.from() | :init_handshake},
          next_id: pos_integer(),
          buffer: String.t(),
          initialized: boolean()
        }

  defstruct [:transport, :transport_state, :requests, :next_id, :buffer, :initialized]

  @doc """
  Starts an MCP client connected to an MCP server.

  The client automatically performs the MCP handshake during initialization.
  The server process will be spawned via the configured transport.

  ## Options

  - `:transport` - Transport module (default: `Stdio`)
  - `:command` - Executable command (for Stdio transport)
  - `:args` - Command-line arguments
  - `:env` - Environment variables as `[{key, value}]`

  ## Returns

  - `{:ok, pid}` - Client started successfully
  - `{:error, reason}` - Failed to start (transport error, process spawn failed)

  ## Examples

      # Connect to a filesystem MCP server
      {:ok, pid} = Client.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"],
        transport: Pincer.Adapters.Connectors.MCP.Transports.Stdio
      )

      # Connect to GitHub MCP server with authentication
      {:ok, pid} = Client.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-github"],
        env: [{"GITHUB_PERSONAL_ACCESS_TOKEN", "ghp_xxx"}]
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Executes a tool on the connected MCP server.

  ## Parameters

  - `pid` - PID of the MCP client
  - `name` - Name of the tool to execute
  - `arguments` - Map of arguments for the tool

  ## Returns

  - `{:ok, response}` - Tool executed successfully, response is the JSON-RPC response map
  - `{:error, reason}` - Execution failed

  ## Timeout

  60 seconds - Tool execution may involve file I/O, API calls, or other slow operations.

  ## Examples

      # Read a file using the filesystem MCP server
      {:ok, response} = Client.call_tool(pid, "read_file", %{"path" => "/home/user/file.txt"})
      
      # Create an issue using the GitHub MCP server  
      {:ok, response} = Client.call_tool(pid, "create_issue", %{
        "owner" => "myorg",
        "repo" => "myrepo",
        "title" => "Bug report",
        "body" => "Description here"
      })

  ## Response Format

  The response follows the MCP specification:

      %{
        "result" => %{
          "content" => [
            %{"type" => "text", "text" => "file contents..."}
          ]
        }
      }
  """
  @spec call_tool(pid(), String.t(), map()) :: {:ok, map()} | {:error, any()}
  def call_tool(pid, name, arguments) do
    GenServer.call(pid, {:call_tool, name, arguments}, 60_000)
  end

  @doc """
  Lists all tools available on the connected MCP server.

  ## Parameters

  - `pid` - PID of the MCP client

  ## Returns

  - `{:ok, response}` - Success, response contains the tools list
  - `{:error, reason}` - Failed to list tools

  ## Timeout

  30 seconds - Allows time for server startup and tool enumeration.

  ## Examples

      {:ok, response} = Client.list_tools(pid)
      tools = response["result"]["tools"]
      
      # Each tool has:
      # - "name" - Tool identifier
      # - "description" - Human-readable description
      # - "inputSchema" - JSON Schema for arguments

  ## Response Format

      %{
        "result" => %{
          "tools" => [
            %{
              "name" => "read_file",
              "description" => "Read the contents of a file",
              "inputSchema" => %{
                "type" => "object",
                "properties" => %{
                  "path" => %{"type" => "string", "description" => "File path"}
                },
                "required" => ["path"]
              }
            }
          ]
        }
      }
  """
  @spec list_tools(pid()) :: {:ok, map()} | {:error, any()}
  def list_tools(pid) do
    GenServer.call(pid, :list_tools, 30_000)
  end

  @impl true
  def init(opts) do
    # Default transport is Stdio for now
    transport_mod = Keyword.get(opts, :transport, Stdio)

    case transport_mod.connect(opts) do
      {:ok, transport_state} ->
        state = %__MODULE__{
          transport: transport_mod,
          transport_state: transport_state,
          requests: %{},
          next_id: 1,
          buffer: "",
          initialized: false
        }

        {:ok, state, {:continue, :initialize}}

      {:error, reason} ->
        Logger.error("Failed to start MCP transport: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:initialize, state) do
    # Send the 'initialize' request (required by MCP protocol)
    id = state.next_id

    payload = %{
      jsonrpc: "2.0",
      id: id,
      method: "initialize",
      params: %{
        protocolVersion: "2024-11-05",
        capabilities: %{},
        clientInfo: %{name: "Pincer", version: "0.1.0"}
      }
    }

    Logger.debug("[MCP Client] Sending Handshake: #{inspect(payload)}")
    send_payload(state, payload)
    {:noreply, %{state | requests: Map.put(state.requests, id, :init_handshake), next_id: id + 1}}
  end

  @impl true
  def handle_call(:list_tools, from, state) do
    id = state.next_id
    payload = %{jsonrpc: "2.0", id: id, method: "tools/list", params: %{}}
    Logger.debug("[MCP Client] Sending ListTools: #{inspect(payload)}")
    send_payload(state, payload)
    {:noreply, %{state | requests: Map.put(state.requests, id, from), next_id: id + 1}}
  end

  @impl true
  def handle_call({:call_tool, name, args}, from, state) do
    id = state.next_id

    payload = %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{name: name, arguments: args}
    }

    Logger.debug(
      "[MCP Client] Sending payload to #{inspect(state.transport_state)}: #{inspect(payload)}"
    )

    send_payload(state, payload)
    {:noreply, %{state | requests: Map.put(state.requests, id, from), next_id: id + 1}}
  end

  @impl true
  def handle_info({_port, {:data, data}}, state) do
    # Delegate parsing to Transport implementation if possible, 
    # but currently Stdio logic is partly here.
    # Refactoring: Stdio transport helper handle_data

    {messages, remaining} = Stdio.handle_data(state.buffer, data)

    new_state = process_transport_messages(messages, %{state | buffer: remaining})

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:mcp_transport, %{} = message}, state) do
    {:noreply, process_transport_messages([message], state)}
  end

  @impl true
  def handle_info({:mcp_transport, messages}, state) when is_list(messages) do
    {:noreply, process_transport_messages(messages, state)}
  end

  @impl true
  def handle_info({_port, {:exit_status, status}}, state) do
    Logger.error("MCP Server exited with status: #{status}")
    {:stop, :normal, state}
  end

  defp handle_response(id, response, state) do
    case Map.pop(state.requests, id) do
      {:init_handshake, updated_requests} ->
        # Send the 'initialized' notification to complete the handshake
        send_payload(state, %{jsonrpc: "2.0", method: "notifications/initialized"})
        %{state | requests: updated_requests, initialized: true}

      {from, updated_requests} ->
        GenServer.reply(from, {:ok, response})
        %{state | requests: updated_requests}

      _ ->
        state
    end
  end

  defp send_payload(state, payload) do
    state.transport.send_message(state.transport_state, payload)
  end

  defp process_transport_messages(messages, state) do
    Enum.reduce(messages, state, fn msg, acc ->
      Logger.debug("[MCP Client] Received message: #{inspect(msg)}")

      case msg do
        %{"id" => id} = response -> handle_response(id, response, acc)
        %{id: id} = response -> handle_response(id, response, acc)
        _ -> acc
      end
    end)
  end
end
