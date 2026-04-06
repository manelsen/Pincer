defmodule Pincer.Contracts.ToolAdapterContractTest do
  @moduledoc """
  Contract tests verifying that all tool adapters implement the Pincer.Ports.Tool behaviour.

  Each tool module must:
  - Declare `@behaviour Pincer.Ports.Tool`
  - Implement `spec/0` returning a tool specification map or list of maps
  - Implement `execute/1` or `execute/2` (both are optional callbacks, but at least one is required)
  """
  use ExUnit.Case, async: true

  @tool_modules [
    Pincer.Adapters.Tools.Browser,
    Pincer.Adapters.Tools.ChannelActions,
    Pincer.Adapters.Tools.CodeSkeleton,
    Pincer.Adapters.Tools.Config,
    Pincer.Adapters.Tools.ExternalKnowledge,
    Pincer.Adapters.Tools.FileSystem,
    Pincer.Adapters.Tools.GitHub,
    Pincer.Adapters.Tools.GitInspect,
    Pincer.Adapters.Tools.GraphMemory,
    Pincer.Adapters.Tools.Learning,
    Pincer.Adapters.Tools.Media,
    Pincer.Adapters.Tools.Orchestrator,
    Pincer.Adapters.Tools.SafeShell,
    Pincer.Adapters.Tools.Scheduler,
    Pincer.Adapters.Tools.Timer,
    Pincer.Adapters.Tools.Web,
    Pincer.Adapters.Tools.Workflow
  ]

  test "tool adapters declare Pincer.Ports.Tool behaviour" do
    Enum.each(@tool_modules, fn tool_module ->
      behaviours = tool_module.module_info(:attributes)[:behaviour] || []

      assert Pincer.Ports.Tool in behaviours,
             "#{inspect(tool_module)} must declare @behaviour Pincer.Ports.Tool"
    end)
  end

  test "tool adapters export spec/0" do
    Enum.each(@tool_modules, fn tool_module ->
      assert function_exported?(tool_module, :spec, 0),
             "#{inspect(tool_module)} must export spec/0"
    end)
  end

  test "tool adapters export execute/1 or execute/2" do
    Enum.each(@tool_modules, fn tool_module ->
      has_execute =
        function_exported?(tool_module, :execute, 1) or
          function_exported?(tool_module, :execute, 2)

      assert has_execute,
             "#{inspect(tool_module)} must export execute/1 or execute/2"
    end)
  end

  test "tool adapter spec/0 returns a map or list of maps" do
    Enum.each(@tool_modules, fn tool_module ->
      result = tool_module.spec()

      is_valid =
        (is_map(result) and Map.has_key?(result, :name)) or
          (is_list(result) and Enum.all?(result, &(is_map(&1) and Map.has_key?(&1, :name))))

      assert is_valid,
             "#{inspect(tool_module)}.spec/0 must return a map with :name or a list of such maps"
    end)
  end
end
