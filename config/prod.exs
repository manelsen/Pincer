import Config

config :pincer, Pincer.Infra.Repo,
  database: Path.expand("../db/pincer_prod.db", Path.dirname(__ENV__.file)),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))
