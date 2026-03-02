defmodule Pincer.Adapters.Connectors.MCP.Transports.HTTPTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Connectors.MCP.Transports.HTTP

  test "connect/1 returns error when URL is missing" do
    assert {:error, :missing_url} = HTTP.connect([])
  end

  test "send_message/2 posts payload with custom headers and forwards response to owner" do
    parent = self()

    requester = fn url, payload, headers ->
      send(parent, {:request_sent, url, payload, headers})
      {:ok, %{"jsonrpc" => "2.0", "id" => 10, "result" => %{"tools" => []}}}
    end

    assert {:ok, state} =
             HTTP.connect(
               url: "https://mcp.example.com/rpc",
               headers: %{"Authorization" => "Bearer abc", "X-Tenant" => "acme"},
               owner: parent,
               requester: requester
             )

    assert :ok =
             HTTP.send_message(state, %{
               jsonrpc: "2.0",
               id: 10,
               method: "tools/list",
               params: %{}
             })

    assert_received {:request_sent, "https://mcp.example.com/rpc", payload, headers}
    assert payload[:method] == "tools/list"
    assert {"Authorization", "Bearer abc"} in headers
    assert {"X-Tenant", "acme"} in headers
    assert_received {:mcp_transport, %{"id" => 10, "result" => %{"tools" => []}}}
  end

  test "send_message/2 returns http_error tuple on non-2xx responses" do
    requester = fn _url, _payload, _headers ->
      {:ok, %{status: 401, body: %{"error" => "unauthorized"}}}
    end

    assert {:ok, state} =
             HTTP.connect(
               url: "https://mcp.example.com/rpc",
               requester: requester
             )

    assert {:error, {:http_error, 401, %{"error" => "unauthorized"}}} =
             HTTP.send_message(state, %{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}})
  end

  test "send_message/2 parses SSE body and forwards incremental transport messages" do
    parent = self()

    requester = fn _url, _payload, _headers ->
      {:ok,
       %{
         status: 200,
         headers: %{"content-type" => "text/event-stream"},
         body: """
         event: message
         data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}

         event: message
         data: {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo"}]}}

         data: [DONE]

         """
       }}
    end

    assert {:ok, state} =
             HTTP.connect(
               url: "https://mcp.example.com/sse",
               owner: parent,
               requester: requester
             )

    assert :ok =
             HTTP.send_message(state, %{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}})

    assert_received {:mcp_transport, [%{"id" => 1, "result" => %{"tools" => []}}, second]}
    assert second["id"] == 2
    assert second["result"]["tools"] == [%{"name" => "echo"}]
  end

  test "send_message/2 ignores heartbeat SSE events and comments" do
    parent = self()

    requester = fn _url, _payload, _headers ->
      {:ok,
       %{
         status: 200,
         headers: %{"content-type" => "text/event-stream"},
         body: """
         : keepalive

         event: heartbeat

         event: message
         data: {"jsonrpc":"2.0","id":9,"result":{"tools":[{"name":"echo"}]}}

         data: [DONE]
         """
       }}
    end

    assert {:ok, state} =
             HTTP.connect(
               url: "https://mcp.example.com/sse",
               owner: parent,
               requester: requester
             )

    assert :ok =
             HTTP.send_message(state, %{jsonrpc: "2.0", id: 9, method: "tools/list", params: %{}})

    assert_received {:mcp_transport,
                     [%{"id" => 9, "result" => %{"tools" => [%{"name" => "echo"}]}}]}
  end

  test "send_message/2 reconnects on interrupted SSE stream with exponential backoff and dedupe" do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    requester = fn _url, _payload, _headers ->
      attempt =
        Agent.get_and_update(counter, fn value ->
          next = value + 1
          {next, next}
        end)

      case attempt do
        1 ->
          {:ok,
           %{
             status: 200,
             headers: %{"content-type" => "text/event-stream"},
             body: """
             event: message
             id: 1
             data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
             """
           }}

        _ ->
          {:ok,
           %{
             status: 200,
             headers: %{"content-type" => "text/event-stream"},
             body: """
             event: message
             id: 1
             data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}

             event: message
             id: 2
             data: {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo"}]}}

             data: [DONE]
             """
           }}
      end
    end

    sleep_fn = fn ms -> send(parent, {:sleep_backoff, ms}) end

    assert {:ok, state} =
             HTTP.connect(
               url: "https://mcp.example.com/sse",
               owner: parent,
               requester: requester,
               max_reconnect_attempts: 2,
               initial_backoff_ms: 10,
               max_backoff_ms: 50,
               sleep_fn: sleep_fn
             )

    assert :ok =
             HTTP.send_message(state, %{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}})

    assert_received {:mcp_transport, [%{"id" => 1, "result" => %{"tools" => []}}]}
    assert_received {:sleep_backoff, 10}

    assert_received {:mcp_transport,
                     [%{"id" => 2, "result" => %{"tools" => [%{"name" => "echo"}]}}]}
  end

  test "send_message/2 stops reconnect loop after max attempts" do
    requester = fn _url, _payload, _headers ->
      {:error, %Req.TransportError{reason: :timeout}}
    end

    assert {:ok, state} =
             HTTP.connect(
               url: "https://mcp.example.com/sse",
               requester: requester,
               max_reconnect_attempts: 1,
               initial_backoff_ms: 1,
               max_backoff_ms: 1,
               sleep_fn: fn _ -> :ok end
             )

    assert {:error, %Req.TransportError{reason: :timeout}} =
             HTTP.send_message(state, %{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}})
  end

  test "send_message/2 returns explicit error for invalid SSE event data" do
    requester = fn _url, _payload, _headers ->
      {:ok,
       %{
         status: 200,
         headers: %{"content-type" => "text/event-stream"},
         body: """
         data: {invalid-json}

         """
       }}
    end

    assert {:ok, state} =
             HTTP.connect(
               url: "https://mcp.example.com/sse",
               requester: requester
             )

    assert {:error, {:invalid_sse_data, _bad_data}} =
             HTTP.send_message(state, %{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}})
  end

  test "close/1 invokes optional closer callback" do
    parent = self()

    closer = fn _state ->
      send(parent, :http_transport_closed)
      :ok
    end

    assert {:ok, state} =
             HTTP.connect(
               url: "https://mcp.example.com/rpc",
               closer: closer
             )

    assert :ok = HTTP.close(state)
    assert_received :http_transport_closed
  end
end
