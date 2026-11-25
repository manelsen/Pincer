import Config

System.put_env("PINCER_STORAGE", "sqlite")
System.put_env("PINCER_SQLITE_PATH", System.get_env("PINCER_SQLITE_PATH", ":memory:"))

config :pincer,
  storage_adapter: Pincer.Adapters.Storage.SQLite,
  sqlite_path: System.get_env("PINCER_SQLITE_PATH", ":memory:"),
  sqlite_vec: :auto,
  sqlite_vec_dimensions: 1024

config :nostrum, token: "DUMMY_TOKEN"

config :pincer,
  discord_api: Pincer.Channels.TestAdapter,
  telegram_api: Pincer.Channels.TestAdapter,
  slack_api: Pincer.Channels.TestAdapter

config :pincer, workspaces_dir: "tmp/test_workspaces"

config :pincer, enable_graph_watcher: false
config :pincer, enable_heartbeat_watchers: false
config :pincer, health_port: 0

# The sandbox pool cannot satisfy StartupGuard's migration check at boot;
# test_helper.exs already creates and migrates the database explicitly.
config :pincer, skip_startup_guard: true
