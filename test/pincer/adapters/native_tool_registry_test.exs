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
    original_enable_browser = Application.get_env(:pincer, :enable_browser)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:pincer, :mcp_manager)
      else
        Application.put_env(:pincer, :mcp_manager, original)
      end

      if is_nil(original_enable_browser) do
        Application.delete_env(:pincer, :enable_browser)
      else
        Application.put_env(:pincer, :enable_browser, original_enable_browser)
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

  test "every native tool spec exposed by the registry is structurally valid" do
    Application.put_env(:pincer, :mcp_manager, MCPManagerTimeoutStub)

    tools =
      NativeToolRegistry.list_tools()
      |> Enum.filter(&Map.has_key?(&1, "_module"))

    assert tools != []

    Enum.each(tools, fn tool ->
      spec =
        case tool["function"] do
          %{"function" => inner} -> inner
          other -> other
        end

      name = spec[:name] || spec["name"]
      description = spec[:description] || spec["description"]
      parameters = spec[:parameters] || spec["parameters"]
      properties = parameters[:properties] || parameters["properties"]
      type = parameters[:type] || parameters["type"]

      assert is_binary(name) and name != ""
      assert is_binary(description) and description != ""
      assert is_map(parameters)
      assert type == "object"
      assert is_map(properties)
    end)

    names =
      Enum.map(tools, fn tool ->
        spec =
          case tool["function"] do
            %{"function" => inner} -> inner
            other -> other
          end

        spec[:name] || spec["name"]
      end)

    assert Enum.uniq(names) == names
  end

  test "channel_actions is exposed by the native registry" do
    Application.put_env(:pincer, :mcp_manager, MCPManagerTimeoutStub)

    names =
      NativeToolRegistry.list_tools()
      |> Enum.filter(&Map.has_key?(&1, "_module"))
      |> Enum.map(fn tool ->
        spec =
          case tool["function"] do
            %{"function" => inner} -> inner
            other -> other
          end

        spec[:name] || spec["name"]
      end)

    assert "channel_actions" in names
  end

  test "registry exposes split web tools instead of legacy web name" do
    Application.put_env(:pincer, :mcp_manager, MCPManagerTimeoutStub)

    names =
      NativeToolRegistry.list_tools()
      |> Enum.filter(&Map.has_key?(&1, "_module"))
      |> Enum.map(fn tool ->
        spec =
          case tool["function"] do
            %{"function" => inner} -> inner
            other -> other
          end

        spec[:name] || spec["name"]
      end)

    assert "web_search" in names
    assert "web_fetch" in names
    refute "web" in names
  end

  test "registry hides browser tool when browser is disabled" do
    Application.put_env(:pincer, :mcp_manager, MCPManagerTimeoutStub)
    Application.put_env(:pincer, :enable_browser, false)

    names =
      NativeToolRegistry.list_tools()
      |> Enum.filter(&Map.has_key?(&1, "_module"))
      |> Enum.map(fn tool ->
        spec =
          case tool["function"] do
            %{"function" => inner} -> inner
            other -> other
          end

        spec[:name] || spec["name"]
      end)

    refute "browser" in names
  end

  test "registry exposes browser tool when browser is enabled" do
    Application.put_env(:pincer, :mcp_manager, MCPManagerTimeoutStub)
    Application.put_env(:pincer, :enable_browser, true)

    names =
      NativeToolRegistry.list_tools()
      |> Enum.filter(&Map.has_key?(&1, "_module"))
      |> Enum.map(fn tool ->
        spec =
          case tool["function"] do
            %{"function" => inner} -> inner
            other -> other
          end

        spec[:name] || spec["name"]
      end)

    assert "browser" in names
  end
end
