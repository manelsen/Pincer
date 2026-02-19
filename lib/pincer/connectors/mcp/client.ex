defmodule Pincer.Connectors.MCP.Client do
  @moduledoc """
  Cliente MCP com suporte a Handshake de inicialização.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def call_tool(pid, name, arguments) do
    GenServer.call(pid, {:call_tool, name, arguments}, 60_000)
  end

  def list_tools(pid) do
    GenServer.call(pid, :list_tools, 30_000)
  end

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    
    try do
      port = Port.open({:spawn_executable, find_executable(command)}, [:binary, :exit_status, args: args])
      state = %{port: port, requests: %{}, next_id: 1, buffer: "", initialized: false}
      {:ok, state, {:continue, :initialize}}
    rescue
      e -> Logger.error("Erro MCP Port: #{inspect(e)}"); {:stop, :port_error}
    end
  end

  @impl true
  def handle_continue(:initialize, state) do
    # Envia o 'initialize' request (obrigatório no protocolo MCP)
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
    send_payload(state.port, payload)
    {:noreply, %{state | requests: Map.put(state.requests, id, :init_handshake), next_id: id + 1}}
  end

  @impl true
  def handle_call(:list_tools, from, state) do
    id = state.next_id
    send_payload(state.port, %{jsonrpc: "2.0", id: id, method: "tools/list", params: %{}})
    {:noreply, %{state | requests: Map.put(state.requests, id, from), next_id: id + 1}}
  end

  @impl true
  def handle_call({:call_tool, name, args}, from, state) do
    id = state.next_id
    send_payload(state.port, %{jsonrpc: "2.0", id: id, method: "tools/call", params: %{name: name, arguments: args}})
    {:noreply, %{state | requests: Map.put(state.requests, id, from), next_id: id + 1}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_buffer = state.buffer <> data
    {messages, remaining} = parse_messages(new_buffer)
    
    new_state = Enum.reduce(messages, %{state | buffer: remaining}, fn msg_json, acc ->
      case Jason.decode(msg_json) do
        {:ok, %{"id" => id} = response} -> handle_response(id, response, acc)
        _ -> acc
      end
    end)
    {:noreply, new_state}
  end

  defp handle_response(id, response, state) do
    case Map.pop(state.requests, id) do
      {:init_handshake, updated_requests} ->
        # Envia a notificação de 'initialized' para concluir o handshake
        send_payload(state.port, %{jsonrpc: "2.0", method: "notifications/initialized"})
        %{state | requests: updated_requests, initialized: true}
      {from, updated_requests} ->
        GenServer.reply(from, {:ok, response})
        %{state | requests: updated_requests}
      _ -> state
    end
  end

  defp send_payload(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")
  end

  defp parse_messages(buffer) do
    parts = String.split(buffer, "\n")
    {List.delete_at(parts, -1), List.last(parts)}
  end

  defp find_executable(cmd), do: System.find_executable(cmd) || cmd
end
