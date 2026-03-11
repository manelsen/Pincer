import Config

config :pincer, :http,
  timeout: 30_000,
  retry_budget: 2

config :pincer, :features,
  hashline_editor: false,
  memory_diagnostics: true
