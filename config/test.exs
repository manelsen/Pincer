import Config

config :pincer, Pincer.Repo,
  database: "pincer_test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10
