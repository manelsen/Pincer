import Config

config :pincer,
  ecto_repos: [Pincer.Repo]

config :telegex,
  token: System.get_env("TELEGRAM_BOT_TOKEN"),
  caller_adapter: {Finch, [name: Pincer.Finch]}

config :pincer, :storage_adapter, Pincer.Storage.Adapters.SQLite

config :nx, default_backend: EXLA.Backend

# Configuração de Logs (Sinal Puro no CLI)
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id],
  level: :warning

config :pincer, Pincer.Repo,
  log: false

import_config "#{config_env()}.exs"
