defmodule Pincer.Adapters.Connectors.MCP.Transport do
  @moduledoc """
  Behaviour defining the contract for MCP (Model Context Protocol) transport implementations.

  MCP is an open protocol that enables AI assistants to discover and use external tools,
  resources, and prompts through a standardized interface. This behaviour abstracts the
  communication layer, allowing different transport mechanisms to be plugged in transparently.

  ## Why Transports?

  MCP servers can communicate through various channels:
  - **Stdio** - Communication via standard input/output (most common)
  - **SSE** - Server-Sent Events over HTTP
  - **WebSocket** - Full-duplex communication
  - **Custom** - Any custom communication protocol

  By implementing this behaviour, new transports can be added without modifying
  the core MCP client logic.

  ## Implementing a Transport

  A transport module must implement the following callbacks:

      defmodule MyTransport do
        @behaviour Pincer.Adapters.Connectors.MCP.Transport

        @impl true
        def connect(opts) do
          # Establish connection and return state
          {:ok, %MyTransport{connection: conn}}
        end

        @impl true
        def send_message(state, message) do
          # Send JSON-RPC message
          :ok
        end

        @impl true
        def close(state) do
          # Clean up resources
          :ok
        end
      end

  ## Message Format

  All messages are JSON-RPC 2.0 compliant maps. The transport is responsible for:
  - Encoding the map to the appropriate wire format
  - Sending the message to the MCP server
  - Receiving responses and forwarding them to the owning process

  ## See Also

  - `Pincer.Adapters.Connectors.MCP.Transports.Stdio` - Standard implementation
  - `Pincer.Adapters.Connectors.MCP.Client` - Client using transports
  """

  @type state :: any()
  @type reason :: any()
  @type opts :: keyword()

  @doc """
  Establishes a connection to an MCP server.

  ## Options

  The options depend on the transport implementation. Common options include:
  - `:command` - The executable command to run (for Stdio)
  - `:args` - Arguments to pass to the command
  - `:env` - Environment variables as a list of `{key, value}` tuples
  - `:owner` - The process that will receive incoming messages (defaults to `self()`)

  ## Returns

  - `{:ok, state}` - Connection successful, state will be passed to other callbacks
  - `{:error, reason}` - Connection failed

  ## Examples

      {:ok, state} = MyTransport.connect(command: "npx", args: ["-y", "@modelcontextprotocol/server-github"])
  """
  @callback connect(opts :: opts()) :: {:ok, state :: state()} | {:error, reason :: reason()}

  @doc """
  Sends a JSON-RPC message to the MCP server.

  ## Parameters

  - `state` - The transport state returned by `connect/1`
  - `message` - A map representing a JSON-RPC 2.0 message

  ## Returns

  - `:ok` - Message sent successfully
  - `{:error, reason}` - Send failed

  ## Examples

      :ok = MyTransport.send_message(state, %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/list",
        params: %{}
      })
  """
  @callback send_message(state :: state(), message :: map()) :: :ok | {:error, reason :: reason()}

  @doc """
  Closes the connection to the MCP server.

  This callback is optional. Implement it if your transport needs cleanup,
  such as closing ports, sockets, or releasing resources.

  ## Parameters

  - `state` - The transport state

  ## Returns

  Always returns `:ok`.

  ## Examples

      :ok = MyTransport.close(state)
  """
  @callback close(state :: state()) :: :ok

  @optional_callbacks close: 1
end
