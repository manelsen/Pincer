import Config

config :pincer, Pincer.Infra.Repo,
  username: System.get_env("PINCER_DB_USER", "postgres"),
  password: System.get_env("PINCER_DB_PASSWORD", "postgres"),
  hostname: System.get_env("PINCER_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("PINCER_DB_PORT", "5432")),
  database: System.get_env("PINCER_DB_NAME", "pincer_prod"),
  types: Pincer.Infra.PostgrexTypes,
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))
