import Config

config :pincer, Pincer.Infra.Repo,
  database: Path.expand("../db/pincer_dev.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
