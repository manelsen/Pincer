import Config

config :pincer, Pincer.Infra.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: System.get_env("PINCER_DB_USER", "postgres"),
  password: System.get_env("PINCER_DB_PASSWORD", "postgres"),
  hostname: System.get_env("PINCER_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("PINCER_DB_PORT", "5432")),
  database: System.get_env("PINCER_DB_NAME", "pincer_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  types: Pincer.Infra.PostgrexTypes,
  ssl: false

config :nostrum, token: "DUMMY_TOKEN"

config :pincer,
  discord_api: Pincer.Channels.TestAdapter,
  telegram_api: Pincer.Channels.TestAdapter,
  slack_api: Pincer.Channels.TestAdapter

config :pincer, storage_adapter: Pincer.Storage.Adapters.Postgres

config :pincer, workspaces_dir: "tmp/test_workspaces"

config :pincer, enable_graph_watcher: false
config :pincer, enable_heartbeat_watchers: false
