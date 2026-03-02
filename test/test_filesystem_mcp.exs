# test_filesystem_mcp.exs

IO.puts("Starting Pincer to test Filesystem MCP...")
Application.ensure_all_started(:pincer)

alias Pincer.Adapters.Connectors.MCP.Manager
Logger.configure(level: :info)

IO.puts("Waiting for MCP tools discovery (10s)...")
Process.sleep(10_000)

tools = Manager.get_all_tools()
fs_tools = Enum.filter(tools, fn t -> t.name in ["read_file", "list_directory", "write_file"] end)

if length(fs_tools) > 0 do
  IO.puts("\n[SUCCESS] Found Filesystem tools:")
  Enum.each(fs_tools, fn t -> IO.puts(" - #{t.name}") end)

  # Try to read a file
  IO.puts("\nTesting 'read_file' on 'mix.exs'...")
  case Manager.execute_tool("read_file", %{"path" => "mix.exs"}) do
    {:ok, content} -> 
      IO.puts("[SUCCESS] Read 'mix.exs' content snippet:")
      IO.puts(String.slice(content, 0, 100) <> "...")
    error ->
      IO.puts("[FAIL] Failed to read file: #{inspect(error)}")
  end

else
  IO.puts("\n[FAIL] No Filesystem tools found.")
end

IO.puts("Done.")
