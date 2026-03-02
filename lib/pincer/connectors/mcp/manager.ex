defmodule Pincer.Connectors.MCP.Manager do
  @moduledoc """
  Manages multiple MCP servers and provides unified tool discovery and execution.

  The Manager is the central orchestrator for MCP integration in Pincer. It:

  - Starts and supervises multiple MCP server connections
  - Discovers tools from all connected servers
  - Provides unified tool listing in OpenAI function format
  - Routes tool execution to the appropriate server

  ## What is MCP?

  MCP (Model Context Protocol) is an open protocol developed by Anthropic that
  standardizes how AI assistants connect to external data sources and tools.
  Think of it as "USB for AI" - a universal way to plug in capabilities.

  ### Key Benefits

  - **Standardized Tool Interface**: One protocol for all tool integrations
  - **Dynamic Discovery**: Tools are discovered at runtime, no hardcoding needed
  - **Ecosystem Compatibility**: Use servers built by the community
  - **Language Agnostic**: MCP servers can be written in any language

  ## Architecture

      ┌─────────────────────────────────────────────────────────────────┐
      │                         MCP Manager                             │
      │  ┌─────────────────────────────────────────────────────────┐    │
      │  │                    Tool Registry                        │    │
      │  │  "read_file" => {pid, spec, "filesystem"}               │    │
      │  │  "create_issue" => {pid, spec, "github"}                │    │
      │  └─────────────────────────────────────────────────────────┘    │
      │                              │                                  │
      │              ┌───────────────┼───────────────┐                  │
      │              ▼               ▼               ▼                  │
      │         ┌────────┐     ┌────────┐     ┌────────┐               │
      │         │Client 1│     │Client 2│     │Client N│               │
      │         │(GitHub)│     │(File)  │     │(...)   │               │
      │         └────────┘     └────────┘     └────────┘               │
      └─────────────────────────────────────────────────────────────────┘

  ## Configuration

  MCP servers are configured in `config/config.exs`:

      config :pincer, :mcp, %{
        "servers" => %{
          "github" => %{
            "command" => "npx",
            "args" => ["-y", "@modelcontextprotocol/server-github"]
          },
          "filesystem" => %{
            "command" => "npx",
            "args" => ["-y", "@modelcontextprotocol/server-filesystem", "/home/user"]
          }
        }
      }

  ### Environment Variables

  Some MCP servers require authentication tokens. Configure them via the
  `:tokens` application environment:

      config :pincer, :tokens, %{
        "github" => System.get_env("GITHUB_TOKEN")
      }

  The Manager automatically injects `GITHUB_PERSONAL_ACCESS_TOKEN` for
  the "github" server.

  ## Tool Discovery

  On startup, the Manager:
  1. Starts all configured MCP servers
  2. Waits for servers to initialize (with retries)
  3. Queries each server for available tools
  4. Builds a unified tool registry

  Discovery includes retry logic (5 attempts) to handle servers that need
  time to download dependencies (e.g., `npx` packages).

  ## OpenAI Compatibility

  Tools are exposed in OpenAI's function calling format, making them
  directly usable with LLM APIs:

      tools = Manager.get_all_tools()
      # => [
      #   %{
      #     name: "read_file",
      #     description: "Read file contents",
      #     parameters: %{type: "object", properties: %{...}}
      #   }
      # ]

  ## Usage

      # Get all available tools
      tools = Pincer.Connectors.MCP.Manager.get_all_tools()

      # Execute a tool
      {:ok, result} = Pincer.Connectors.MCP.Manager.execute_tool("read_file", %{
        "path" => "/home/user/file.txt"
      })

  ## Error Handling

  - Unknown tools return `{:error, :tool_not_found}`
  - Server failures are logged, other servers continue operating
  - Tool execution timeout is 120 seconds

  ## Supervision

  MCP clients are started under `Pincer.MCP.Supervisor` (a DynamicSupervisor).
  Clients use `:transient` restart strategy - they will be restarted if they
  crash, but repeated failures won't crash the supervisor.

  ## See Also

  - `Pincer.Connectors.MCP.Client` - Individual server client
  - `Pincer.Connectors.MCP.Transport` - Transport behaviour
  """

  use GenServer
  require Logger
  alias Pincer.Connectors.MCP.Client
  alias Pincer.Connectors.MCP.ConfigLoader
  alias Pincer.Connectors.MCP.SidecarAudit
  alias Pincer.Connectors.MCP.SkillsSidecarPolicy
  alias Pincer.Connectors.MCP.Transports.HTTP
  alias Pincer.Connectors.MCP.Transports.Stdio
  @default_get_tools_timeout 200
  @skills_sidecar_tool_timeout_ms 15_000
  @skills_sidecar_hard_kill_timeout_ms 100

  @doc """
  Starts the MCP Manager process.

  The manager is registered under the module name and must be started
  before any MCP operations can be performed.

  ## Returns

  - `{:ok, pid}` - Manager started successfully
  - `{:error, reason}` - Failed to start

  ## Examples

      {:ok, _pid} = Pincer.Connectors.MCP.Manager.start_link([])
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{servers: %{}, tools: %{}}, name: __MODULE__)
  end

  @doc false
  @spec build_client_opts(String.t(), map(), map()) :: keyword()
  def build_client_opts(server_name, cfg, tokens \\ %{})
      when is_binary(server_name) and is_map(cfg) and is_map(tokens) do
    transport = transport_module(cfg)

    case transport do
      Stdio ->
        env =
          cfg
          |> cfg_value("env", [])
          |> normalize_env()
          |> maybe_add_github_token(server_name, tokens)

        [
          command: cfg_value(cfg, "command"),
          args: cfg_value(cfg, "args", []),
          env: env,
          transport: transport
        ]

      HTTP ->
        [
          url: cfg_value(cfg, "url") || cfg_value(cfg, "base_url"),
          headers: normalize_headers(cfg_value(cfg, "headers", [])),
          transport: transport
        ]

      other ->
        [transport: other]
    end
  end

  @doc """
  Returns all tools discovered from connected MCP servers.

  Tools are returned in OpenAI's function calling format, ready for use
  with LLM APIs that support function calling.

  ## Returns

  A list of tool specifications:

      [
        %{
          name: "tool_name",
          description: "What this tool does",
          parameters: %{type: "object", properties: %{...}, required: [...]}
        }
      ]

  ## Examples

      tools = Manager.get_all_tools()
      
      # Use with OpenAI API
      OpenAI.chat_completion(
        model: "gpt-4",
        messages: messages,
        tools: tools
      )

  ## Note

  Returns an empty list if no MCP servers are configured or if
  all servers failed to start.
  """
  @spec get_all_tools(timeout :: non_neg_integer()) :: [map()]
  def get_all_tools(timeout \\ @default_get_tools_timeout)

  def get_all_tools(timeout) when is_integer(timeout) and timeout >= 0 do
    GenServer.call(__MODULE__, :get_tools, timeout)
  catch
    :exit, reason ->
      Logger.warning("MCP Manager unavailable for get_all_tools: #{inspect(reason)}")
      []
  end

  @doc false
  @spec resolve_servers_config(map(), keyword()) :: map()
  def resolve_servers_config(mcp_config, opts \\ []) when is_map(mcp_config) do
    mcp_config
    |> cfg_value("servers", %{})
    |> ConfigLoader.merge_static_and_dynamic(opts)
    |> enforce_sidecar_policy()
  end

  @doc """
  Executes a tool on the appropriate MCP server.

  The Manager automatically routes the execution to the server that
  provides the requested tool.

  ## Parameters

  - `name` - The tool name (must match a discovered tool)
  - `arguments` - A map of arguments for the tool

  ## Returns

  - `{:ok, result}` - Tool executed successfully, result is the text content
  - `{:error, :tool_not_found}` - No server provides this tool
  - `{:error, reason}` - Tool execution failed

  ## Timeout

  120 seconds - Long timeout to accommodate slow operations like
  file processing or API calls.

  ## Examples

      # Read a file
      {:ok, content} = Manager.execute_tool("read_file", %{"path" => "/home/user/doc.txt"})

      # Create a GitHub issue
      {:ok, issue_url} = Manager.execute_tool("create_issue", %{
        "owner" => "myorg",
        "repo" => "myrepo",
        "title" => "Bug found",
        "body" => "Details here"
      })

      # Handle unknown tool
      {:error, :tool_not_found} = Manager.execute_tool("unknown_tool", %{})

  ## Response Processing

  The Manager extracts text content from MCP responses. If a tool returns
  multiple content items, text items are concatenated.
  """
  @spec execute_tool(String.t(), map()) :: {:ok, String.t()} | {:error, any()}
  def execute_tool(name, arguments) do
    GenServer.call(__MODULE__, {:execute, name, arguments}, 120_000)
  end

  @doc false
  @spec audit_sidecar_result(String.t(), String.t(), integer(), any(), module(), map()) :: any()
  def audit_sidecar_result(
        server_name,
        tool_name,
        started_at_ms,
        result,
        audit_module \\ SidecarAudit,
        arguments \\ %{}
      )
      when is_binary(server_name) and is_binary(tool_name) and is_integer(started_at_ms) do
    if server_name == "skills_sidecar" do
      duration_ms = max(System.monotonic_time(:millisecond) - started_at_ms, 0)
      status = audit_module.status_from_result(result)
      metadata = sidecar_audit_metadata(arguments)

      _ =
        audit_module.emit(
          metadata.skill_id,
          tool_name,
          duration_ms,
          status,
          Map.drop(metadata, [:skill_id])
        )
    end

    result
  end

  @doc false
  @spec call_tool_with_timeout(String.t(), (-> any()), non_neg_integer(), non_neg_integer()) ::
          any()
  def call_tool_with_timeout(
        server_name,
        call_fun,
        timeout_ms \\ @skills_sidecar_tool_timeout_ms,
        kill_timeout_ms \\ @skills_sidecar_hard_kill_timeout_ms
      )
      when is_binary(server_name) and is_function(call_fun, 0) and is_integer(timeout_ms) and
             timeout_ms >= 0 and is_integer(kill_timeout_ms) and kill_timeout_ms >= 0 do
    if server_name == "skills_sidecar" do
      task = Task.async(call_fun)

      case Task.yield(task, timeout_ms) do
        {:ok, result} ->
          result

        nil ->
          _ = Task.shutdown(task, kill_timeout_ms)
          {:error, :timeout}
      end
    else
      call_fun.()
    end
  end

  # Callbacks

  @impl true
  def init(_) do
    {:ok, %{servers: %{}, tools: %{}}, {:continue, :load_servers}}
  end

  @impl true
  def handle_continue(:load_servers, state) do
    mcp_config = Application.get_env(:pincer, :mcp, %{})
    servers_config = resolve_servers_config(mcp_config)
    tokens = Application.get_env(:pincer, :tokens, %{})

    new_servers =
      Enum.reduce(servers_config, %{}, fn {name, cfg}, acc ->
        client_opts = build_client_opts(name, cfg, tokens)

        spec = %{
          id: name,
          start: {Client, :start_link, [client_opts]},
          # Try to restart, but don't crash the supervisor if it fails repeatedly
          restart: :transient
        }

        case DynamicSupervisor.start_child(Pincer.MCP.Supervisor, spec) do
          {:ok, pid} ->
            Map.put(acc, name, pid)

          {:error, reason} ->
            Logger.error("Failed to start MCP server #{name}: #{inspect(reason)}")
            acc
        end
      end)

    # Try to collect tools with retries (waiting for npx/download)
    new_tools = discover_tools_with_retry(new_servers, 5)

    Logger.info(
      "MCP Manager: #{map_size(new_tools)} tools discovered in #{map_size(new_servers)} servers."
    )

    {:noreply, %{state | servers: new_servers, tools: new_tools}}
  end

  defp discover_tools_with_retry(servers, retries) when retries > 0 do
    # Wait a bit before trying
    Process.sleep(5000)

    tools =
      Enum.reduce(servers, %{}, fn {server_name, pid}, acc ->
        case Client.list_tools(pid) do
          {:ok, %{"result" => %{"tools" => tools}}} ->
            Enum.reduce(tools, acc, fn tool, inner_acc ->
              Logger.debug("Tool discovered [#{server_name}]: #{tool["name"]}")

              Map.put(inner_acc, tool["name"], %{
                server_pid: pid,
                spec: tool,
                server_name: server_name
              })
            end)

          _ ->
            acc
        end
      end)

    if map_size(tools) == 0 and map_size(servers) > 0 do
      Logger.warning("No MCP tools found. Trying again... (#{retries} remaining)")

      discover_tools_with_retry(servers, retries - 1)
    else
      tools
    end
  end

  defp discover_tools_with_retry(_servers, 0), do: %{}

  @impl true
  def handle_call(:get_tools, _from, state) do
    # Convert MCP specs to OpenAI format used by Pincer
    openai_specs =
      Enum.map(state.tools, fn {name, info} ->
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
      nil ->
        {:reply, {:error, :tool_not_found}, state}

      info ->
        started_at_ms = System.monotonic_time(:millisecond)

        result =
          info.server_name
          |> call_tool_with_timeout(fn -> Client.call_tool(info.server_pid, name, args) end)
          |> case do
            {:ok, %{"result" => %{"content" => content}}} ->
              # MCP returns a list of contents (text, image, etc)
              text_content =
                content
                |> Enum.filter(fn c -> c["type"] == "text" end)
                |> Enum.map(fn c -> c["text"] end)
                |> Enum.join("
")

              {:ok, text_content}

            {:ok, %{"error" => error}} ->
              {:error, error}

            error ->
              error
          end

        audited_result =
          audit_sidecar_result(info.server_name, name, started_at_ms, result, SidecarAudit, args)

        {:reply, audited_result, state}
    end
  end

  defp sidecar_audit_metadata(args) when is_map(args) do
    %{
      skill_id: normalize_audit_value(args, "skill_id", "skills_sidecar"),
      skill_version: normalize_audit_value(args, "skill_version", "unknown"),
      artifact_checksum: normalize_audit_value(args, "artifact_checksum", "unknown")
    }
  end

  defp sidecar_audit_metadata(_args) do
    %{
      skill_id: "skills_sidecar",
      skill_version: "unknown",
      artifact_checksum: "unknown"
    }
  end

  defp normalize_audit_value(args, key, default) do
    value = Map.get(args, key) || Map.get(args, String.to_atom(key))

    cond do
      is_nil(value) ->
        default

      is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      is_atom(value) ->
        Atom.to_string(value)

      is_integer(value) ->
        Integer.to_string(value)

      true ->
        default
    end
  end

  defp transport_module(cfg) do
    case cfg_value(cfg, "transport") || cfg_value(cfg, "transport_module") do
      mod when is_atom(mod) and not is_nil(mod) ->
        mod

      transport when is_binary(transport) ->
        case String.downcase(String.trim(transport)) do
          "http" -> HTTP
          "https" -> HTTP
          "sse" -> HTTP
          "http_sse" -> HTTP
          "stdio" -> Stdio
          _ -> Stdio
        end

      _ ->
        Stdio
    end
  end

  defp cfg_value(cfg, key, default \\ nil) when is_map(cfg) do
    case Map.get(cfg, key) do
      nil -> Map.get(cfg, String.to_atom(key), default)
      value -> value
    end
  end

  defp maybe_add_github_token(env, "github", tokens) do
    case Map.get(tokens, "github") || Map.get(tokens, :github) do
      token when is_binary(token) and token != "" ->
        if Enum.any?(env, fn {k, _v} -> k == "GITHUB_PERSONAL_ACCESS_TOKEN" end) do
          env
        else
          env ++ [{"GITHUB_PERSONAL_ACCESS_TOKEN", token}]
        end

      _ ->
        env
    end
  end

  defp maybe_add_github_token(env, _server_name, _tokens), do: env

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce(headers, [], fn
      {k, v}, acc -> [{to_string(k), to_string(v)} | acc]
      _other, acc -> acc
    end)
    |> Enum.reverse()
  end

  defp normalize_headers(_), do: []

  defp normalize_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_env(env) when is_list(env) do
    Enum.reduce(env, [], fn
      {k, v}, acc -> [{to_string(k), to_string(v)} | acc]
      _other, acc -> acc
    end)
    |> Enum.reverse()
  end

  defp normalize_env(_), do: []

  defp enforce_sidecar_policy(servers) when is_map(servers) do
    case Map.fetch(servers, "skills_sidecar") do
      :error ->
        servers

      {:ok, cfg} ->
        case SkillsSidecarPolicy.validate(cfg) do
          :ok ->
            servers

          {:error, reason} ->
            Logger.warning(
              "MCP skills_sidecar disabled due to insecure isolation config: #{inspect(reason)}"
            )

            Map.delete(servers, "skills_sidecar")
        end
    end
  end
end
