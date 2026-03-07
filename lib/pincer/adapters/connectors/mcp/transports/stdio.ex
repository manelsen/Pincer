defmodule Pincer.Adapters.Connectors.MCP.Transports.Stdio do
  @moduledoc """
  Stdio transport implementation for MCP using Erlang Ports.

  This is the most common transport for MCP servers, where communication
  happens through standard input/output streams. The MCP server is spawned
  as an external process, and JSON-RPC messages are exchanged via NDJSON
  (Newline-Delimited JSON).

  ## Architecture

      ┌─────────────┐     stdin/stdout     ┌──────────────────┐
      │   Pincer    │ ◄─────────────────► │   MCP Server     │
      │   Client    │     (via Port)      │   (Node/Python)  │
      └─────────────┘                     └──────────────────┘

  ## Usage

  This transport is typically used through the MCP Client:

      {:ok, pid} = Pincer.Adapters.Connectors.MCP.Client.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/dir"],
        transport: Pincer.Adapters.Connectors.MCP.Transports.Stdio
      )

  ## Configuration

  When starting an MCP server via Stdio, you can provide:

  - `:command` (required) - The executable to run
  - `:args` - List of command-line arguments
  - `:env` - List of `{key, value}` tuples for environment variables
  - `:owner` - Process to receive port messages (defaults to caller)

  ## Environment Variables

  Environment variables are useful for passing API tokens:

      env = [{"GITHUB_PERSONAL_ACCESS_TOKEN", "ghp_xxx"}]
      {:ok, state} = Stdio.connect(command: "npx", args: ["-y", "@modelcontextprotocol/server-github"], env: env)

  ## Message Protocol

  The transport uses NDJSON (Newline-Delimited JSON):
  - Each outgoing message is encoded as JSON and terminated with `\\n`
  - Each incoming message is expected to be one JSON object per line
  - Non-JSON lines (like server logs) are logged at INFO level and ignored

  ## Error Handling

  The port is linked to the owning process. If the MCP server crashes,
  the owner will receive an `{:exit_status, status}` message.

  ## See Also

  - `Pincer.Adapters.Connectors.MCP.Transport` - The behaviour this module implements
  - `Pincer.Adapters.Connectors.MCP.Client` - Client that uses this transport
  """

  @behaviour Pincer.Adapters.Connectors.MCP.Transport
  require Logger

  @type t :: %__MODULE__{
          port: port(),
          buffer: String.t(),
          owner: pid()
        }

  defstruct [:port, :buffer, :owner]

  @impl true
  @doc """
  Spawns an MCP server process and establishes stdio communication.

  ## Options

  - `:command` (required) - The executable command to run
  - `:args` - List of command-line arguments (default: `[]`)
  - `:env` - List of `{key, value}` tuples for environment variables
  - `:owner` - Process to receive incoming messages (default: `self()`)

  ## Returns

  - `{:ok, %Stdio{}}` - Connection successful with transport state
  - `{:error, exception}` - Failed to spawn the process

  ## Examples

      {:ok, state} = Stdio.connect(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-github"],
        env: [{"GITHUB_PERSONAL_ACCESS_TOKEN", "ghp_xxx"}]
      )

  ## Notes

  - Stderr is merged into stdout (`:stderr_to_stdout`)
  - The port is linked to the calling process
  - If the executable is not in PATH, provide an absolute path
  """
  @spec connect(keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def connect(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    owner = Keyword.get(opts, :owner, self())

    try do
      env_vars = Keyword.get(opts, :env, [])

      port_env =
        Enum.map(env_vars, fn {k, v} ->
          {to_charlist(k), to_charlist(v)}
        end)

      port_opts = [:binary, :exit_status, :stderr_to_stdout, args: args, env: port_env]
      executable = System.find_executable(command) || command
      port = Port.open({:spawn_executable, executable}, port_opts)

      {:ok, %__MODULE__{port: port, buffer: "", owner: owner}}
    rescue
      e -> {:error, e}
    end
  end

  @impl true
  @doc """
  Sends a JSON-RPC message to the MCP server via stdin.

  The message is encoded as JSON and terminated with a newline character,
  following the NDJSON protocol used by MCP stdio transport.

  ## Parameters

  - `state` - The transport state from `connect/1`
  - `message` - A map representing a JSON-RPC 2.0 message

  ## Returns

  - `:ok` - Message sent successfully
  - `{:error, exception}` - Encoding or send failed

  ## Examples

      :ok = Stdio.send_message(state, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{protocolVersion: "2024-11-05"}
      })
  """
  @spec send_message(t(), map()) :: :ok | {:error, Exception.t()}
  def send_message(%__MODULE__{port: port}, message) do
    try do
      json = Jason.encode!(message)
      Port.command(port, json <> "\n")
      :ok
    rescue
      e -> {:error, e}
    end
  end

  @impl true
  @doc """
  Closes the port connection to the MCP server.

  This terminates the spawned process. Any pending messages will be lost.

  ## Parameters

  - `state` - The transport state

  ## Returns

  Always returns `:ok`.

  ## Examples

      :ok = Stdio.close(state)
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{port: port}) do
    Port.close(port)
    :ok
  end

  @doc """
  Parses raw data from the port into a list of JSON messages.

  This function handles the NDJSON protocol, where each line is expected
  to be a complete JSON object. It maintains a buffer for incomplete lines
  that span multiple data chunks.

  ## Parameters

  - `buffer` - The accumulated buffer from previous calls (may be empty)
  - `new_data` - New data received from the port

  ## Returns

  A tuple `{messages, remaining_buffer}` where:
  - `messages` - A list of decoded JSON maps
  - `remaining_buffer` - Unparsed data waiting for more input

  ## Handling Non-JSON Lines

  If a line cannot be parsed as JSON (common with server logs or stderr output),
  the line is logged at INFO level and skipped. This provides resilience against
  noisy MCP server implementations.

  ## Examples

      # First chunk with complete message
      {[%{"jsonrpc" => "2.0", "result" => %{"tools" => []}}], ""} = 
        Stdio.handle_data("", ~s({"jsonrpc":"2.0","result":{"tools":[]}}\n))

      # Incomplete message across chunks
      {[], ~s({"jsonrpc":"2.0")} = Stdio.handle_data("", ~s({"jsonrpc":"2.0"))
      {[%{"jsonrpc" => "2.0"}], ""} = Stdio.handle_data(~s({"jsonrpc":"2.0"), ~s(}\n))

  ## Usage in Client

  This function should be called by the process receiving port messages:

      def handle_info({port, {:data, data}}, state) do
        {messages, remaining} = Stdio.handle_data(state.buffer, data)
        # Process messages...
        {:noreply, %{state | buffer: remaining}}
      end
  """
  @spec handle_data(String.t(), String.t()) :: {[map()], String.t()}
  def handle_data(buffer, new_data) do
    full_buffer = buffer <> new_data
    extract_messages(full_buffer, [])
  end

  defp extract_messages("", acc), do: {Enum.reverse(acc), ""}

  defp extract_messages(buffer, acc) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        if String.trim(line) == "" do
          extract_messages(rest, acc)
        else
          case Jason.decode(line) do
            {:ok, msg} ->
              extract_messages(rest, [msg | acc])

            {:error, _} ->
              # If we cannot decode a line, it might be that the message contains newlines 
              # (which is valid JSON but invalid for NDJSON protocol usually, unless escaped).
              # However, many MCP implementations assume NDJSON (one JSON per line).
              # If the buffer has a newline but it's not a valid JSON, it might be a partial JSON 
              # that unfortunately included a newline (bad) OR it's just log noise.

              # Heuristic: Check if the line is a complete JSON object by brace counting?
              # For this MVP, we stick to NDJSON strictness but log warning for dropped lines.
              # If we want to support newline-in-json, we would need a valid JSON tokenizer.

              # Let's assume for now that if it fails to decode, we shouldn't discard it immediately 
              # if it looks like it could be part of a larger object?
              # OR we assume standard MCP is strict NDJSON. 
              # Given the previous error "write EPIPE", the issue was likely process crash.

              # Let's try to be resilient: if it fails, maybe it is log output.
              # We log it and move on to 'rest'.
              # If not JSON, assume it's a server log (captured stderr or dirty stdout)
              if String.trim(line) != "" do
                if Application.get_env(:pincer, :log_mcp),
                  do: Logger.debug("[MCP Server Log] #{String.trim(line)}")
              end

              extract_messages(rest, acc)
          end
        end

      [incomplete] ->
        {Enum.reverse(acc), incomplete}
    end
  end
end
