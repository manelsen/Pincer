# test_orchestration.exs
# Verifies the full orchestration flow:
# 1. Start Blackboard
# 2. Dispatch a SubAgent (via direct call to simulate 'dispatch_agent' tool)
# 3. Simulate SubAgent work
# 4. Read Blackboard

IO.puts("Starting Pincer.Core.Orchestration Test...")
Application.ensure_all_started(:pincer)

alias Pincer.Core.Orchestration.Blackboard
alias Pincer.Adapters.Tools.Orchestrator
alias Pincer.Adapters.Tools.BlackboardReader

# 1. Ensure Blackboard is running
case Process.whereis(Blackboard) do
  nil -> Blackboard.start_link([])
  pid -> IO.puts("Blackboard already running at #{inspect(pid)}")
end

# 2. Dispatch a Sub-Agent
IO.puts("Dispatching Sub-Agent...")
result = Orchestrator.execute(%{"goal" => "Count to 3 and report."})
IO.puts("Dispatch Result: #{result}")

# 3. Monitor Blackboard
IO.puts("Monitoring Blackboard (5s)...")
Enum.each(1..5, fn i ->
  Process.sleep(1000)
  IO.puts("Tick #{i}...")
  
  # Read Blackboard manually using the tool
  bb_content = BlackboardReader.execute(%{})
  if bb_content != "Blackboard is empty." do
    IO.puts("\n[BLACKBOARD UPDATE]:\n#{bb_content}\n")
  end
end)

IO.puts("Done.")
