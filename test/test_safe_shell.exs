# test_safe_shell.exs
IO.puts("Starting Safe Shell & Approval Test...")
Application.ensure_all_started(:pincer)

alias Pincer.PubSub
alias Pincer.Core.Executor
alias Pincer.Session.Server

# 1. Setup Session
session_id = "safe_shell_test_#{:os.system_time(:seconds)}"
Pincer.PubSub.subscribe("session:#{session_id}")

# 2. Test Case A: Whitelisted Command (ls)
IO.puts("\n--- Case A: Whitelisted Command (ls) ---")
# We need an Executor PID
history = [%{"role" => "user", "content" => "List files in current dir."}]
{:ok, executor_pid} = Executor.start(self(), session_id, history)

# Wait for completion
receive do
  {:executor_finished, _history, response} ->
    IO.puts("[SUCCESS] Whitelisted command executed. Response length: #{String.length(response)}")
    # IO.puts("Response: #{response}")
after
  15_000 ->
    IO.puts("[FAIL] Whitelisted command timed out.")
end

# 3. Test Case B: Non-whitelisted Command (rm -rf /tmp/test)
IO.puts("\n--- Case B: Approval Required (rm -rf) ---")
# Create a dummy file to 'remove' safely in our test
File.touch("tmp_test_file")

history_b = [%{"role" => "user", "content" => "Execute: rm tmp_test_file"}]
# We start a Session to have the full infrastructure
{:ok, session_pid} = Server.start_link(session_id: session_id)
Server.process_input(session_id, "Execute: rm tmp_test_file")

# Wait for approval requested broadcast
receive do
  {:approval_requested, call_id, command} ->
    IO.puts("[RECEIVED] Approval Requested for id: #{call_id}, cmd: #{command}")
    
    # Simulate User Approval
    IO.puts("Simulating 'GRANTED'...")
    Server.approve_tool(session_id, call_id)

  other ->
    IO.puts("Ignored msg: #{inspect(other)}")
after
  20_000 ->
    IO.puts("[FAIL] Approval request not received.")
end

# Check if command executed
receive do
  {:agent_response, _res} ->
    IO.puts("[SUCCESS] Command executed after approval.")
    if not File.exists?("tmp_test_file") do
        IO.puts("[SUCCESS] File 'tmp_test_file' was actually deleted.")
    else
        IO.puts("[FAIL] File still exists.")
    end
after
  10_000 ->
    IO.puts("[FAIL] Executor did not finish after approval.")
end
