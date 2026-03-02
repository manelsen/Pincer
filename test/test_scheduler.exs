# test_scheduler.exs
IO.puts("Starting Scheduler Test...")
Application.ensure_all_started(:pincer)

alias Pincer.PubSub
alias Pincer.Session.Server

# 1. Setup Environment
session_id = "sched_test_#{:os.system_time(:seconds)}"
heartbeat_file = "HEARTBEAT.md"

# Write a test heartbeat file with a task that runs every 1 second
File.write!(heartbeat_file, """
# Test Heartbeat
- [ ] Say 'Scheduler Works' (every 1s)
""")

# 2. Subscribe to Session Events
Pincer.PubSub.subscribe("session:#{session_id}")

# 3. Start Session (which starts Scheduler)
IO.puts("Starting Session #{session_id}...")
{:ok, _pid} = Server.start_link(session_id: session_id)

# Wait for process registry
Process.sleep(1000)

# Force Tick
IO.puts("Forcing Scheduler Tick...")
send(Pincer.Orchestration.Scheduler, :tick)

# 4. Wait for Trigger
IO.puts("Waiting for scheduled task trigger...")

receive do
  {:agent_status, msg} ->
    IO.puts("\n[RECEIVED] Agent Status: #{msg}")
    if String.contains?(msg, "Scheduler Works") do
      IO.puts("[SUCCESS] Scheduled task triggered!")
    else
      IO.puts("[FAIL] Received status but text mismatch.")
    end

  {:agent_thinking, msg} ->
    IO.puts("\n[RECEIVED] Agent Thinking: #{msg}")
    if String.contains?(msg, "Sub-Agente") do
      IO.puts("[SUCCESS] Sub-Agent spawned!")
      # End test successfully
      System.halt(0)
    end

  other ->
    IO.puts("Ignored msg: #{inspect(other)}")
after
  15_000 ->
    IO.puts("\n[TIMEOUT] Scheduled task did not trigger in 15s.")
    System.halt(1)
end
