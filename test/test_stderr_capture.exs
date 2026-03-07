# test_stderr_capture.exs
# Simulates a process that writes garbage to stderr
# Expectation: Stdio transport should log warnings, not crash

IO.puts("Starting Mock Process Test...")

# Create a mock script that writes to stderr
File.write!("mock_stderr.sh", """
#!/bin/bash
echo '{"jsonrpc": "2.0", "id": 1, "result": "ok"}'
echo "ERROR: This is a stderr log" >&2
echo "Another error line" >&2
sleep 1
""")

File.chmod!("mock_stderr.sh", 0o755)

alias Pincer.Adapters.Connectors.MCP.Transports.Stdio

# Start the transport manually
{:ok, state} = Stdio.connect(command: "./mock_stderr.sh")

# Wait a bit for the process to run
Process.sleep(500)

# Simulate receiving data (Port sends message to owner)
# Since we are the owner, let's flush messages
receive do
  {_port, {:data, data}} ->
    IO.puts("\nReceived data chunk:")
    IO.inspect(data)

    # Process it with handle_data
    {msgs, buffer} = Stdio.handle_data("", data)
    IO.puts("\nParsed Messages: #{length(msgs)}")
    IO.inspect(msgs)

    IO.puts("\nRemaining Buffer: #{inspect(buffer)}")
after
  2000 -> IO.puts("No data received!")
end

# Clean up
File.rm!("mock_stderr.sh")
