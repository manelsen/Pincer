# test_github_mcp.exs

IO.puts("Starting Pincer to test GitHub MCP...")
Application.ensure_all_started(:pincer)

alias Pincer.Connectors.MCP.Manager
Logger.configure(level: :debug)
# Force console backend to show debug logs
:logger.set_handler_config(:default, :level, :debug) # For OTP 21+ logger default handler
# Or for Elixir Logger wrapper if using legacy console backend
try do
  Logger.configure_backend(:console, level: :debug)
rescue
  _ -> :ok
end

IO.puts("Waiting for MCP tools discovery (10s)...")
Process.sleep(10_000)

tools = Manager.get_all_tools()
IO.puts("Discovered #{length(tools)} tools.")

IO.puts("\n[SUCCESS] List of all #{length(tools)} discovered tools:")
Enum.each(tools, fn t -> IO.puts(" - #{t.name}") end)

IO.puts("Done.")
