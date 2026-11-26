defmodule Pincer.Adapters.NativeToolRegistry do
  @moduledoc """
  Adapter for native Elixir tools.

  Implements the `Pincer.Ports.ToolRegistry` port by serving
  the core Pincer tools and dynamically connected MCP tools.
  """
  @behaviour Pincer.Ports.ToolRegistry
  require Logger

  alias Pincer.Adapters.Connectors.MCP.Manager, as: MCPManager

  # Direct external shell tools bypass SafeShell/WorkspaceGuard/approval policy.
  @blocked_mcp_tools MapSet.new(["run_command"])

  @native_tools [
    Pincer.Adapters.Tools.FileSystem,
    Pincer.Adapters.Tools.Config,
    Pincer.Adapters.Tools.Scheduler,
    Pincer.Adapters.Tools.Timer,
    Pincer.Adapters.Tools.GitHub,
    Pincer.Adapters.Tools.GitInspect,
    Pincer.Adapters.Tools.ChannelActions,
    Pincer.Adapters.Tools.Orchestrator,
    Pincer.Adapters.Tools.BlackboardReader,
    Pincer.Adapters.Tools.SafeShell,
    Pincer.Adapters.Tools.Web,
    Pincer.Adapters.Tools.GraphMemory,
    Pincer.Adapters.Tools.CodeSkeleton,
    Pincer.Adapters.Tools.Learning,
    Pincer.Adapters.Tools.ExternalKnowledge,
    Pincer.Adapters.Tools.Browser,
    Pincer.Adapters.Tools.Media,
    Pincer.Adapters.Tools.SessionSearch,
    Pincer.Adapters.Tools.Workflow
  ]

  @impl true
  def list_tools do
    native_specs =
      Enum.flat_map(@native_tools, fn m ->
        case m.spec() do
          list when is_list(list) ->
            Enum.map(list, fn s ->
              s |> normalize_spec() |> Map.put("_module", m)
            end)

          single ->
            [single |> normalize_spec() |> Map.put("_module", m)]
        end
      end)

    mcp_specs =
      list_mcp_tools()
      |> Enum.reject(&blocked_mcp_tool?/1)
      |> Enum.map(fn s ->
        %{"type" => "function", "function" => s, "_type" => :mcp}
      end)

    native_specs ++ mcp_specs
  end

  defp normalize_spec(%{"type" => "function", "function" => _} = spec), do: spec

  defp normalize_spec(function_spec) when is_map(function_spec) do
    %{"type" => "function", "function" => function_spec}
  end

  @impl true
  def execute_tool(name, args, context) do
    # 1. Check native tools
    native_match =
      Enum.find(@native_tools, fn m ->
        case m.spec() do
          list when is_list(list) ->
            Enum.any?(list, fn s ->
              spec = normalize_spec(s)
              (spec["function"]["name"] || spec["function"][:name]) == name
            end)

          single ->
            spec = normalize_spec(single)
            (spec["function"]["name"] || spec["function"][:name]) == name
        end
      end)

    cond do
      native_match ->
        started_at_ms = System.monotonic_time(:millisecond)
        Logger.info("[TOOL] Executing native: #{name} #{format_arg_metadata(args)}")
        result = execute_native(native_match, name, args, context)
        duration_ms = elapsed_ms(started_at_ms)

        case result do
          {:ok, _} ->
            Logger.info("[TOOL] SUCCESS: #{name} duration_ms=#{duration_ms}")

          {:error, reason} ->
            Logger.error(
              "[TOOL] ERROR: #{name} duration_ms=#{duration_ms} -> #{inspect(reason, limit: 20, printable_limit: 256)}"
            )
        end

        result

      # 2. Check MCP (excluding blocked shell-bypass tools)
      MapSet.member?(@blocked_mcp_tools, name) ->
        Logger.warning("[TOOL] Blocked direct MCP execution for #{name}")
        {:error, "Tool #{name} is blocked for direct MCP execution; use safe_shell."}

      true ->
        started_at_ms = System.monotonic_time(:millisecond)
        Logger.info("[TOOL] Executing MCP: #{name} #{format_arg_metadata(args)}")

        case mcp_manager().execute_tool(name, args) do
          {:ok, c} ->
            Logger.info("[TOOL] SUCCESS: #{name} duration_ms=#{elapsed_ms(started_at_ms)}")
            {:ok, c}

          {:error, :tool_not_found} ->
            Logger.error("[TOOL] NOT FOUND: #{name} duration_ms=#{elapsed_ms(started_at_ms)}")
            {:error, "Tool #{name} not found."}

          {:error, r} ->
            Logger.error(
              "[TOOL] ERROR: #{name} duration_ms=#{elapsed_ms(started_at_ms)} -> #{inspect(r, limit: 20, printable_limit: 256)}"
            )

            {:error, "Error: #{inspect(r)}"}
        end
    end
  end

  defp elapsed_ms(started_at_ms),
    do: max(System.monotonic_time(:millisecond) - started_at_ms, 0)

  defp format_arg_metadata(args) when is_map(args) do
    keys =
      args
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == "tool_name"))
      |> Enum.sort()
      |> Enum.join(",")

    action = Map.get(args, "action") || Map.get(args, :action)

    action_prefix =
      if is_binary(action) and byte_size(action) <= 64 and
           Regex.match?(~r/^[a-zA-Z0-9_.:-]+$/, action) do
        "action=#{action} "
      else
        ""
      end

    "#{action_prefix}keys=[#{keys}]"
  end

  defp format_arg_metadata(_args), do: "keys=[]"

  defp execute_native(module, name, args, context) do
    # In native tools, we often inject the tool_name into args for convenience
    args_with_meta = Map.put(args, "tool_name", name)

    # Some older or simpler tools might only accept 1 argument (arity 1).
    # New ones should accept 2 (args, context).
    if function_exported?(module, :execute, 2) do
      module.execute(args_with_meta, context)
    else
      # Fallback: merge context into args for arity-1 functions
      module.execute(Map.merge(args_with_meta, context))
    end
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

  defp blocked_mcp_tool?(spec) when is_map(spec) do
    name = spec[:name] || spec["name"]
    is_binary(name) and MapSet.member?(@blocked_mcp_tools, name)
  end

  defp blocked_mcp_tool?(_), do: false
end
