defmodule Pincer.Adapters.Connectors.MCP.Manager do
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
      tools = Pincer.Adapters.Connectors.MCP.Manager.get_all_tools()

      # Execute a tool
      {:ok, result} = Pincer.Adapters.Connectors.MCP.Manager.execute_tool("read_file", %{
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

  - `Pincer.Adapters.Connectors.MCP.Client` - Individual server client
  - `Pincer.Adapters.Connectors.MCP.Transport` - Transport behaviour
  """

  use GenServer
  require Logger
  alias Pincer.Adapters.Connectors.MCP.Client
  alias Pincer.Adapters.Connectors.MCP.ConfigLoader
  alias Pincer.Adapters.Connectors.MCP.SidecarAudit
  alias Pincer.Core.LLM.SkillsSidecarPolicy
  alias Pincer.Adapters.Connectors.MCP.Transports.HTTP
  alias Pincer.Adapters.Connectors.MCP.Transports.Stdio
  @default_get_tools_timeout 200
  @lookup_timeout_ms 5_000
  @skills_sidecar_tool_timeout_ms 15_000
  @skills_sidecar_hard_kill_timeout_ms 100

  @doc """
  Starts the MCP Manager process.

  The manager is registered under the module name by default (`name: __MODULE__`)
  unless overridden with `name: nil` or a custom name.

  ## Returns

  - `{:ok, pid}` - Manager started successfully
  - `{:error, reason}` - Failed to start

  ## Examples

      {:ok, _pid} = Pincer.Adapters.Connectors.MCP.Manager.start_link([])
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
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
  @spec get_all_tools() :: [map()]
  def get_all_tools, do: get_all_tools(__MODULE__, @default_get_tools_timeout)

  @spec get_all_tools(non_neg_integer() | GenServer.server()) :: [map()]
  def get_all_tools(timeout) when is_integer(timeout) and timeout >= 0,
    do: get_all_tools(__MODULE__, timeout)

  def get_all_tools(server), do: get_all_tools(server, @default_get_tools_timeout)

  @spec get_all_tools(GenServer.server(), non_neg_integer()) :: [map()]
  def get_all_tools(server, timeout) when is_integer(timeout) and timeout >= 0 do
    GenServer.call(server, :get_tools, timeout)
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
  def execute_tool(name, arguments) when is_binary(name) and is_map(arguments) do
    execute_tool(__MODULE__, name, arguments)
  end

  @doc """
  Executes a tool on a specific `Manager` instance outside its GenServer loop so
  concurrent tool calls do not serialize behind one process.
  """
  @spec execute_tool(GenServer.server(), String.t(), map()) :: {:ok, String.t()} | {:error, any()}
  def execute_tool(server, name, arguments) when is_binary(name) and is_map(arguments) do
    case GenServer.call(server, {:lookup_tool, name}, @lookup_timeout_ms) do
      {:ok, info, client_module} ->
        run_tool_execution(info, name, arguments, client_module)

      {:error, :tool_not_found} ->
        {:error, :tool_not_found}
    end
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
      task = start_unlinked_task(Pincer.TaskSupervisor, call_fun)

      case Task.yield(task, timeout_ms) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error, reason}

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
  def init(opts) do
    opts = if is_list(opts), do: opts, else: []

    state = %{
      servers: %{},
      tools: %{},
      injected_servers: Keyword.get(opts, :servers),
      retry_interval_ms: Keyword.get(opts, :retry_interval_ms, 5_000),
      max_retries: Keyword.get(opts, :max_retries, 5),
      client_module: Keyword.get(opts, :client_module, Client),
      task_supervisor: Keyword.get(opts, :task_supervisor, Pincer.TaskSupervisor),
      discovery_task: nil
    }

    {:ok, state, {:continue, :load_servers}}
  end

  @impl true
  def handle_continue(:load_servers, state) do
    new_servers =
      if is_map(state.injected_servers) do
        state.injected_servers
      else
        start_configured_servers()
      end

    if map_size(new_servers) > 0 and state.max_retries > 0 do
      Process.send_after(self(), {:discover_tools, state.max_retries}, state.retry_interval_ms)
    end

    {:noreply, %{state | servers: new_servers}}
  end

  @impl true
  def handle_info({:discover_tools, retries_left}, %{discovery_task: nil} = state)
      when retries_left > 0 do
    if map_size(state.servers) > 0 do
      servers = state.servers
      client_module = state.client_module

      task =
        start_unlinked_task(state.task_supervisor, fn ->
          discover_tools_once(servers, client_module)
        end)

      {:noreply, %{state | discovery_task: {task.ref, retries_left}}}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, tools}, %{discovery_task: {ref, retries_left}} = state) do
    Process.demonitor(ref, [:flush])

    if map_size(tools) == 0 and map_size(state.servers) > 0 and retries_left > 1 do
      Logger.warning("No MCP tools found. Trying again... (#{retries_left - 1} remaining)")
      Process.send_after(self(), {:discover_tools, retries_left - 1}, state.retry_interval_ms)
    else
      Logger.info(
        "MCP Manager: #{map_size(tools)} tools discovered in #{map_size(state.servers)} servers."
      )
    end

    {:noreply, %{state | tools: tools, discovery_task: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{discovery_task: {ref, retries_left}} = state
      ) do
    Logger.warning("MCP discovery task exited (#{inspect(reason)}).")

    if map_size(state.servers) > 0 and retries_left > 1 do
      Process.send_after(self(), {:discover_tools, retries_left - 1}, state.retry_interval_ms)
    end

    {:noreply, %{state | discovery_task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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

  def handle_call({:lookup_tool, name}, _from, state) do
    case Map.get(state.tools, name) do
      nil -> {:reply, {:error, :tool_not_found}, state}
      info -> {:reply, {:ok, info, state.client_module}, state}
    end
  end

  def handle_call({:execute, name, args}, from, state) do
    case Map.get(state.tools, name) do
      nil ->
        {:reply, {:error, :tool_not_found}, state}

      info ->
        client_module = state.client_module

        start_supervised_fire_and_forget(state.task_supervisor, fn ->
          reply = run_tool_execution(info, name, args, client_module)
          GenServer.reply(from, reply)
        end)

        {:noreply, state}
    end
  end

  defp start_configured_servers do
    mcp_config = Application.get_env(:pincer, :mcp, %{})
    servers_config = resolve_servers_config(mcp_config)
    tokens = Application.get_env(:pincer, :tokens, %{})

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
  end

  defp discover_tools_once(servers, client_module) do
    Enum.reduce(servers, %{}, fn {server_name, pid}, acc ->
      if Process.alive?(pid) do
        try do
          case client_module.list_tools(pid) do
            {:ok, %{"result" => %{"tools" => tools}}} ->
              Enum.reduce(tools, acc, fn tool, inner_acc ->
                if Application.get_env(:pincer, :log_mcp),
                  do: Logger.debug("Tool discovered [#{server_name}]: #{tool["name"]}")

                Map.put(inner_acc, tool["name"], %{
                  server_pid: pid,
                  spec: tool,
                  server_name: server_name
                })
              end)

            _ ->
              acc
          end
        catch
          :exit, _reason -> acc
        end
      else
        acc
      end
    end)
  end

  defp run_tool_execution(info, name, args, client_module) do
    started_at_ms = System.monotonic_time(:millisecond)

    result =
      info.server_name
      |> call_tool_with_timeout(fn -> client_module.call_tool(info.server_pid, name, args) end)
      |> normalize_tool_response()

    audit_sidecar_result(info.server_name, name, started_at_ms, result, SidecarAudit, args)
  end

  defp normalize_tool_response({:ok, %{"result" => %{"content" => content}}}) do
    text_content =
      content
      |> Enum.filter(fn c -> c["type"] == "text" end)
      |> Enum.map(fn c -> c["text"] end)
      |> Enum.join("\n")

    {:ok, text_content}
  end

  defp normalize_tool_response({:ok, %{"error" => error}}), do: {:error, error}
  defp normalize_tool_response(other), do: other

  defp start_unlinked_task(task_supervisor, fun) do
    if Process.whereis(task_supervisor) do
      Task.Supervisor.async_nolink(task_supervisor, fun)
    else
      Task.Supervisor.async_nolink(Pincer.TaskSupervisor, fun)
    end
  catch
    :exit, _ -> Task.async(fun)
  end

  defp start_supervised_fire_and_forget(task_supervisor, fun) do
    if Process.whereis(task_supervisor) do
      Task.Supervisor.start_child(task_supervisor, fun)
    else
      Task.start(fun)
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
    value = fetch_map_value(args, key)

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
    fetch_map_value(cfg, key, default)
  end

  defp fetch_map_value(map, key, default \\ nil) when is_map(map) do
    case Map.get(map, key) do
      nil ->
        case safe_existing_atom(key) do
          {:ok, atom_key} -> Map.get(map, atom_key, default)
          :error -> default
        end

      value ->
        value
    end
  end

  defp safe_existing_atom(key) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end

  defp safe_existing_atom(_), do: :error

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
