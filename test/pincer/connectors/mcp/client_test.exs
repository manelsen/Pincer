defmodule Pincer.Connectors.MCP.ClientTest do
  use ExUnit.Case, async: true

  alias Pincer.Connectors.MCP.Client

  defmodule FakeTransport do
    @behaviour Pincer.Connectors.MCP.Transport

    @impl true
    def connect(opts) do
      {:ok, %{owner: Keyword.get(opts, :owner, self())}}
    end

    @impl true
    def send_message(%{owner: owner}, payload) do
      method = payload[:method] || payload["method"]
      id = payload[:id] || payload["id"]

      case method do
        "initialize" ->
          send(owner, {:mcp_transport, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}})

        "tools/list" ->
          send(owner, {:mcp_transport, list_tools_response(id)})

        "tools/call" ->
          send(owner, {:mcp_transport, tool_call_response(id)})

        "notifications/initialized" ->
          :ok

        _ ->
          :ok
      end

      :ok
    end

    @impl true
    def close(_state), do: :ok

    defp list_tools_response(id) do
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "tools" => [
            %{
              "name" => "echo",
              "description" => "Echo text",
              "inputSchema" => %{"type" => "object"}
            }
          ]
        }
      }
    end

    defp tool_call_response(id) do
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{
          "content" => [%{"type" => "text", "text" => "ok"}]
        }
      }
    end
  end

  test "list_tools/1 works with non-stdio transport messages" do
    assert {:ok, pid} = Client.start_link(transport: FakeTransport)
    assert {:ok, %{"result" => %{"tools" => tools}}} = Client.list_tools(pid)
    assert [%{"name" => "echo"}] = tools
  end

  test "call_tool/3 works with non-stdio transport messages" do
    assert {:ok, pid} = Client.start_link(transport: FakeTransport)

    assert {:ok, %{"result" => %{"content" => [%{"text" => "ok"}]}}} =
             Client.call_tool(pid, "echo", %{"text" => "hello"})
  end
end
