import Config

config :pincer, Pincer.Repo,
  adapter: Ecto.Adapters.SQLite3,
  database: "db/pincer_test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :nostrum, token: "DUMMY_TOKEN"

config :pincer,
  discord_api: Pincer.Channels.TestAdapter,
  telegram_api: Pincer.Channels.TestAdapter,
  slack_api: Pincer.Channels.TestAdapter

config :pincer, storage_adapter: Pincer.Storage.Adapters.SQLite
