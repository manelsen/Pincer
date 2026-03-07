defmodule Pincer.Adapters.NativeToolRegistry do
  @moduledoc """
  Adapter for native Elixir tools.

  Implements the `Pincer.Ports.ToolRegistry` port by serving
  the core Pincer tools and dynamically connected MCP tools.
  """
  @behaviour Pincer.Ports.ToolRegistry
  require Logger

  alias Pincer.Adapters.Connectors.MCP.Manager, as: MCPManager

  @native_tools [
    Pincer.Adapters.Tools.FileSystem,
    Pincer.Adapters.Tools.Config,
    Pincer.Adapters.Tools.Scheduler,
    Pincer.Adapters.Tools.Timer,
    Pincer.Adapters.Tools.GitHub,
    Pincer.Adapters.Tools.Orchestrator,
    Pincer.Adapters.Tools.BlackboardReader,
    Pincer.Adapters.Tools.SafeShell,
    Pincer.Adapters.Tools.Web,
    Pincer.Adapters.Tools.GraphMemory,
    Pincer.Adapters.Tools.CodeSkeleton,
    Pincer.Adapters.Tools.Learning
  ]

  @impl true
  def list_tools do
    native_specs =
      Enum.flat_map(@native_tools, fn m ->
        case m.spec() do
          list when is_list(list) ->
            Enum.map(list, fn s ->
              %{"type" => "function", "function" => s, "_module" => m}
            end)

          single ->
            [%{"type" => "function", "function" => single, "_module" => m}]
        end
      end)

    mcp_specs =
      list_mcp_tools()
      |> Enum.map(fn s ->
        %{"type" => "function", "function" => s, "_type" => :mcp}
      end)

    native_specs ++ mcp_specs
  end

  @impl true
  def execute_tool(name, args, context) do
    # 1. Check native tools
    native_match =
      Enum.find(@native_tools, fn m ->
        case m.spec() do
          list when is_list(list) -> Enum.any?(list, fn s -> s.name == name end)
          single -> single.name == name
        end
      end)

    cond do
      native_match ->
        execute_native(native_match, name, args, context)

      # 2. Check MCP
      true ->
        case mcp_manager().execute_tool(name, args) do
          {:ok, c} -> {:ok, c}
          {:error, :tool_not_found} -> {:error, "Tool #{name} not found."}
          {:error, r} -> {:error, "Error: #{inspect(r)}"}
        end
    end
  end

  defp execute_native(module, name, args, context) do
    args_with_context =
      args
      |> Map.merge(context)
      |> Map.put("tool_name", name)

    module.execute(args_with_context)
  end

  defp list_mcp_tools do
    mcp_manager().get_all_tools()
  rescue
    error ->
      Logger.warning("[MCP] Tool discovery failed: #{Exception.message(error)}")
      []
  catch
    :exit, reason ->
      Logger.warning("[MCP] Tool discovery unavailable (exit): #{inspect(reason)}")
      []
  end

  defp mcp_manager do
    Application.get_env(:pincer, :mcp_manager, MCPManager)
  end
end
