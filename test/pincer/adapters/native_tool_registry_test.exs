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

  defmodule MCPManagerWithShellStub do
    def get_all_tools do
      [
        %{
          name: "run_command",
          description: "Bypass shell",
          parameters: %{type: "object", properties: %{"command" => %{type: "string"}}}
        },
        %{
          name: "mcp_echo",
          description: "Echo",
          parameters: %{type: "object", properties: %{}}
        }
      ]
    end

    def execute_tool(name, args) do
      send(self(), {:unexpected_mcp_exec, name, args})
      {:ok, "bypassed"}
    end
  end

  defmodule MCPManagerSecretOkStub do
    def get_all_tools do
      [
        %{
          name: "mcp_secret_tool",
          description: "Secret tool",
          parameters: %{type: "object", properties: %{}}
        }
      ]
    end

    def execute_tool(_name, _args), do: {:ok, "done"}
  end

  defmodule MCPManagerContextStub do
    def get_all_tools, do: []

    def get_tools_for_context(%{"agent_id" => "agent_a"}) do
      [
        %{
          name: "scoped_mcp_tool",
          description: "Scoped tool",
          parameters: %{type: "object", properties: %{}}
        }
      ]
    end

    def get_tools_for_context(_ctx), do: []

    def execute_tool_with_context(name, args, context) do
      send(self(), {:mcp_exec_with_context, name, args, context})

      if context["agent_id"] == "agent_a" do
        {:ok, "scoped-ok"}
      else
        {:error, {:mcp_access_denied, "scoped_srv"}}
      end
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

  test "filters blocked run_command from MCP tool catalog and rejects direct execution" do
    Application.put_env(:pincer, :mcp_manager, MCPManagerWithShellStub)

    tools = NativeToolRegistry.list_tools()

    refute Enum.any?(tools, fn tool ->
             name = get_in(tool, ["function", :name]) || get_in(tool, ["function", "name"])
             name == "run_command"
           end)

    assert Enum.any?(tools, fn tool ->
             tool["_type"] == :mcp and get_in(tool, ["function", :name]) == "mcp_echo"
           end)

    assert {:error, reason} =
             NativeToolRegistry.execute_tool("run_command", %{"command" => "id"}, %{})

    assert reason =~ ~r/blocked|safe_shell/i
    refute_received {:unexpected_mcp_exec, _, _}
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

  test "logs tool metadata without raw argument values at INFO level for native and MCP tools" do
    import ExUnit.CaptureLog

    Application.put_env(:pincer, :mcp_manager, MCPManagerSecretOkStub)
    original_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn -> Logger.configure(level: original_level) end)

    native_log =
      capture_log([level: :info], fn ->
        {:ok, _res} =
          NativeToolRegistry.execute_tool(
            "read_blackboard",
            %{"action" => "read", "secret_note" => "super_secret_token_123"},
            %{"workspace_path" => File.cwd!()}
          )
      end)

    assert native_log =~ "[TOOL] Executing native: read_blackboard"
    assert native_log =~ "[TOOL] SUCCESS: read_blackboard"
    assert native_log =~ "action=read"
    assert native_log =~ "keys=[action,secret_note]"
    assert native_log =~ "duration_ms="
    refute native_log =~ "super_secret_token_123"

    mcp_log =
      capture_log([level: :info], fn ->
        assert {:ok, "done"} =
                 NativeToolRegistry.execute_tool(
                   "mcp_secret_tool",
                   %{"api_key" => "mcp_secret_value_456", "query" => "hello"},
                   %{}
                 )
      end)

    assert mcp_log =~ "[TOOL] Executing MCP: mcp_secret_tool"
    assert mcp_log =~ "[TOOL] SUCCESS: mcp_secret_tool"
    assert mcp_log =~ "keys="
    assert mcp_log =~ "duration_ms="
    refute mcp_log =~ "mcp_secret_value_456"
    refute mcp_log =~ "hello"
  end

  test "propagates verified session context to MCP discovery and execution" do
    Application.put_env(:pincer, :mcp_manager, MCPManagerContextStub)

    ctx_a = %{"session_id" => "tg_1", "agent_id" => "agent_a", "workspace_path" => "/tmp/ws_a"}
    ctx_b = %{"session_id" => "tg_2", "agent_id" => "agent_b", "workspace_path" => "/tmp/ws_b"}

    tools_a = NativeToolRegistry.list_tools(ctx_a)
    tools_b = NativeToolRegistry.list_tools(ctx_b)

    assert Enum.any?(tools_a, &(get_in(&1, ["function", :name]) == "scoped_mcp_tool"))
    refute Enum.any?(tools_b, &(get_in(&1, ["function", :name]) == "scoped_mcp_tool"))

    assert {:ok, "scoped-ok"} =
             NativeToolRegistry.execute_tool("scoped_mcp_tool", %{"q" => "ok"}, ctx_a)

    assert_received {:mcp_exec_with_context, "scoped_mcp_tool", %{"q" => "ok"}, ^ctx_a}

    assert {:error, reason} =
             NativeToolRegistry.execute_tool("scoped_mcp_tool", %{"q" => "ok"}, ctx_b)

    assert reason =~ "mcp_access_denied"
  end
end
