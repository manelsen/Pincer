# test_monitor_pubsub.exs
Application.ensure_all_started(:pincer)
alias Pincer.PubSub

IO.puts("Monitoring Pincer PubSub...")

# Monitor cli_user
PubSub.subscribe("session:cli_user")
IO.puts("Subscribed to session:cli_user")

# We can't subscribe to all telegram topics easily without knowing IDs, 
# but we can try to find them in registry.
# For now, let's just wait and see if anything comes to cli_user when we use Telegram.

receive_loop = fn loop ->
  receive do
    msg ->
      IO.puts("\n[PUB/SUB EVENT] #{inspect(msg)}")
      loop.(loop)
  end
end

receive_loop.(receive_loop)
