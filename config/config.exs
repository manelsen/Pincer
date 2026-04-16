import Config

config :pincer,
  ecto_repos: [Pincer.Infra.Repo]

config :telegex,
  token: System.get_env("TELEGRAM_BOT_TOKEN"),
  caller_adapter: {Finch, [name: Pincer.Finch]}

config :pincer, :storage_adapter, Pincer.Storage.Adapters.Postgres

config :pincer, :llm_providers, %{
  "google" => %{
    adapter: Pincer.LLM.Providers.Google,
    env_key: "GOOGLE_API_KEY",
    default_model: "gemini-2.0-flash",
    # Gemini suporta leitura nativa de PDFs e imagens via inlineData.
    supports_files: true
  },
  "openrouter" => %{
    adapter: Pincer.LLM.Providers.OpenRouter,
    env_key: "OPENROUTER_API_KEY",
    default_model: "google/gemini-2.0-flash-exp:free"
  },
  "opencode_zen" => %{
    adapter: Pincer.LLM.Providers.OpencodeZen,
    env_key: "OPENCODE_ZEN_API_KEY",
    default_model: "kimi-k2.5-free"
  },
  "z_ai" => %{
    adapter: Pincer.LLM.Providers.Zhipu,
    env_key: "Z_AI_API_KEY",
    default_model: "glm-4.7"
  },
  "z_ai_coding" => %{
    adapter: Pincer.LLM.Providers.Zhipu,
    base_url: "https://api.z.ai/api/coding/paas/v4/chat/completions",
    env_key: "Z_AI_CODING_API_KEY",
    default_model: "glm-4.7"
  },
  "moonshot" => %{
    adapter: Pincer.LLM.Providers.Moonshot,
    env_key: "MOONSHOT_API_KEY",
    default_model: "moonshot-v1-auto"
  },
  "moonshot_coding" => %{
    adapter: Pincer.LLM.Providers.Moonshot,
    env_key: "MOONSHOT_CODING_API_KEY",
    default_model: "moonshot-v1-auto"
  },
  "groq" => %{
    adapter: Pincer.LLM.Providers.Groq,
    env_key: "GROQ_API_KEY",
    default_model: "llama-3.3-70b-versatile"
  },
  "groq_whisper" => %{
    adapter: Pincer.LLM.Providers.GroqWhisper,
    env_key: "GROQ_API_KEY",
    default_model: "whisper-large-v3-turbo"
  },
  "minimax" => %{
    adapter: Pincer.LLM.Providers.MiniMax,
    env_key: "MINIMAX_API_KEY",
    default_model: "MiniMax-M1"
  }
}

# Runtime default is overridden by config.yaml's llm.provider at startup (see Pincer.Infra.Config.load/0)
config :pincer, :default_llm_provider, "openrouter"

config :pincer, :tool_adapters, [Pincer.Adapters.NativeToolRegistry]

# Configuração de Logs
config :logger,
  level: :info,
  colors: [enabled: true, info: :cyan, warn: :yellow, error: :red, debug: :magenta]

config :logger, :default_formatter,
  format: {Pincer.Utils.LoggerFormatter, :format},
  metadata: [:session_id, :project_id, :module]

config :pincer, Pincer.Infra.Repo,
  adapter: Ecto.Adapters.Postgres,
  types: Pincer.Infra.PostgrexTypes,
  log: false

config :pincer, :webhook_token, System.get_env("PINCER_WEBHOOK_TOKEN", "")

config :pincer, :log_mcp, false

config :nostrum,
  token: System.get_env("DISCORD_BOT_TOKEN") || "DISCORD_TOKEN_REQUIRED_FOR_CHANNEL",
  gateway_intents: [:guild_messages, :message_content, :direct_messages]

# ---------------------------------------------------------------------------
# Runtime tunables — override in config/runtime.exs or env-specific files
# ---------------------------------------------------------------------------

# Executor
config :pincer, :approval_timeout_ms, 600_000
config :pincer, :max_recursion_depth, 100
config :pincer, :tool_result_max_chars, 32_000
config :pincer, :max_inline_bytes, 6_291_456

# File system tool
config :pincer, :fs_max_file_size, 52_428_800
config :pincer, :fs_max_search_results, 100
config :pincer, :fs_snippet_limit, 160

# Session
config :pincer, :max_history_messages, 100

# LLM retry policy
config :pincer, :llm_retry,
  max_retries: 5,
  initial_backoff: 2000,
  max_backoff: 30_000,
  max_elapsed_ms: 120_000

# Circuit breaker
config :pincer, :circuit_breaker_threshold, 5
config :pincer, :circuit_breaker_recovery_ms, 30_000

import_config "#{config_env()}.exs"
