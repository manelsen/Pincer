defmodule Pincer.Adapters.NativeToolRegistryTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.NativeToolRegistry

  defmodule MCPManagerTimeoutStub do
    def get_all_tools do
      exit({:timeout, {GenServer, :call, [self(), :get_tools, 5_000]}})
    end
  end

  defmodule MCPManagerOkStub do
    def get_all_tools do
      [
        %{
          name: "mcp_echo",
          description: "Echo",
          parameters: %{type: "object", properties: %{}}
        }
      ]
    end
  end

  setup do
    original = Application.get_env(:pincer, :mcp_manager)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:pincer, :mcp_manager)
      else
        Application.put_env(:pincer, :mcp_manager, original)
      end
    end)

    :ok
  end

  test "returns native tools when MCP manager exits on timeout" do
    Application.put_env(:pincer, :mcp_manager, MCPManagerTimeoutStub)

    tools = NativeToolRegistry.list_tools()

    assert is_list(tools)
    assert Enum.any?(tools, &Map.has_key?(&1, "_module"))
    refute Enum.any?(tools, &Map.has_key?(&1, "_type"))
  end

  test "merges MCP tools into native tool list when MCP manager is available" do
    Application.put_env(:pincer, :mcp_manager, MCPManagerOkStub)

    tools = NativeToolRegistry.list_tools()

    assert Enum.any?(tools, &Map.has_key?(&1, "_module"))

    assert Enum.any?(tools, fn tool ->
             tool["_type"] == :mcp and get_in(tool, ["function", :name]) == "mcp_echo"
           end)
  end
end
