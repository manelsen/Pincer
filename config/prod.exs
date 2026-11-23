import Config

config :logger, level: :info

config :pincer,
  sqlite_path: System.get_env("PINCER_SQLITE_PATH", "data/pincer.db"),
  sqlite_vec: :auto
