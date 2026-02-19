defmodule Pincer.Connectors.MCP.Manager do
  @moduledoc """
  Gerencia múltiplos servidores MCP e unifica suas ferramentas para o Pincer.
  """
  use GenServer
  require Logger
  alias Pincer.Connectors.MCP.Client

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{servers: %{}, tools: %{}}, name: __MODULE__)
  end

  @doc """
  Retorna todas as ferramentas descobertas via MCP no formato spec do OpenAI.
  """
  def get_all_tools do
    GenServer.call(__MODULE__, :get_tools)
  end

  @doc """
  Executa uma ferramenta MCP.
  """
  def execute_tool(name, arguments) do
    GenServer.call(__MODULE__, {:execute, name, arguments}, 120_000)
  end

  # Callbacks

  @impl true
  def init(_) do
    {:ok, %{servers: %{}, tools: %{}}, {:continue, :load_servers}}
  end

  @impl true
  def handle_continue(:load_servers, state) do
    mcp_config = Application.get_env(:pincer, :mcp, %{})
    servers_config = Map.get(mcp_config, "servers", %{})

    new_servers = Enum.reduce(servers_config, %{}, fn {name, cfg}, acc ->
      spec = %{
        id: name,
        start: {Client, :start_link, [[command: cfg["command"], args: cfg["args"]]]},
        restart: :temporary
      }

      case DynamicSupervisor.start_child(Pincer.MCP.Supervisor, spec) do
        {:ok, pid} -> Map.put(acc, name, pid)
        {:error, reason} ->
          Logger.error("Falha ao iniciar servidor MCP #{name}: #{inspect(reason)}")
          acc
      end
    end)

    # Tenta coletar as ferramentas com retries (esperando o npx/download)
    new_tools = discover_tools_with_retry(new_servers, 5)

    Logger.info("MCP Manager: #{map_size(new_tools)} ferramentas descobertas em #{map_size(new_servers)} servidores.")

    {:noreply, %{state | servers: new_servers, tools: new_tools}}
  end

  defp discover_tools_with_retry(servers, retries) when retries > 0 do
    # Aguarda um pouco antes de tentar
    Process.sleep(5000)
    
    tools = Enum.reduce(servers, %{}, fn {server_name, pid}, acc ->
      case Client.list_tools(pid) do
        {:ok, %{"result" => %{"tools" => tools}}} ->
          Enum.reduce(tools, acc, fn tool, inner_acc ->
            Logger.debug("Ferramenta descoberta [#{server_name}]: #{tool["name"]}")
            Map.put(inner_acc, tool["name"], %{server_pid: pid, spec: tool, server_name: server_name})
          end)
        _ -> acc
      end
    end)

    if map_size(tools) == 0 and map_size(servers) > 0 do
      Logger.warning("Nenhuma ferramenta MCP encontrada. Tentando novamente... (#{retries} restantes)")
      discover_tools_with_retry(servers, retries - 1)
    else
      tools
    end
  end

  defp discover_tools_with_retry(_servers, 0), do: %{}

  @impl true
  def handle_call(:get_tools, _from, state) do
    # Converte as specs do MCP para o formato OpenAI que o Pincer usa
    openai_specs = Enum.map(state.tools, fn {name, info} ->
      %{
        name: name,
        description: info.spec["description"],
        parameters: info.spec["inputSchema"]
      }
    end)
    {:reply, openai_specs, state}
  end

  @impl true
  def handle_call({:execute, name, args}, _from, state) do
    case Map.get(state.tools, name) do
      nil -> {:reply, {:error, :tool_not_found}, state}
      info ->
        case Client.call_tool(info.server_pid, name, args) do
          {:ok, %{"result" => %{"content" => content}}} ->
            # MCP retorna uma lista de conteúdos (texto, imagem, etc)
            text_content = 
              content 
              |> Enum.filter(fn c -> c["type"] == "text" end)
              |> Enum.map(fn c -> c["text"] end)
              |> Enum.join("
")
            
            {:reply, {:ok, text_content}, state}
          {:ok, %{"error" => error}} ->
            {:reply, {:error, error}, state}
          error ->
            {:reply, error, state}
        end
    end
  end
end
