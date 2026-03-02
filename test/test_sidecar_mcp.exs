# test_sidecar_mcp.exs

IO.puts("Starting Pincer to test Node Sidecar MCP...")

# Ensure application is started
Application.ensure_all_started(:pincer)

alias Pincer.Adapters.Connectors.MCP.Manager

# Wait a bit for the MCP Manager to discover tools
IO.puts("Waiting for MCP tools discovery (5s)...")
Process.sleep(5000)

tools = Manager.get_all_tools()

IO.puts("\n=== Discovered MCP Tools ===")
Enum.each(tools, fn tool ->
  IO.puts("- #{tool["name"]}: #{tool["description"]}")
end)

IO.puts("\n=== Testing calculate_profits ===")
case Manager.execute_tool("calculate_profits", %{"filename" => "dados_cliente.csv"}) do
  {:ok, result} ->
    IO.puts("✅ Success!")
    IO.inspect(result)

  {:error, reason} ->
    IO.puts("❌ Failed to parse CSV:")
    IO.inspect(reason)
end
