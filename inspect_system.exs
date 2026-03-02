# inspect_system.exs
Application.ensure_all_started(:pincer)

IO.puts("\n--- Pincer Session Registry ---")
Registry.select(Pincer.Session.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
|> Enum.each(fn {id, pid, _} -> IO.puts("#{id}: #{inspect(pid)}") end)

IO.puts("\n--- Pincer PubSub Registry (By Topics) ---")
# PubSub uses :duplicate keys, so topics are keys
Registry.select(Pincer.PubSub.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
|> Enum.each(fn {topic, pid, _} -> IO.puts("#{topic}: #{inspect(pid)}") end)
