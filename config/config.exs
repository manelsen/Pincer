import Config

config :telegex,
  token: System.get_env("TELEGRAM_BOT_TOKEN"),
  caller_adapter: Finch

config :pincer, :storage_adapter, Pincer.Adapters.Storage.SQLite
config :pincer, :audit_log_adapter, Pincer.Adapters.Storage.AuditLog
config :pincer, :dead_letter_queue_adapter, Pincer.Adapters.Storage.DeadLetterQueue
config :pincer, :introspection_store_adapter, Pincer.Adapters.Storage.Introspection
config :pincer, :sqlite_path, System.get_env("PINCER_SQLITE_PATH", "data/pincer.db")
config :pincer, :sqlite_vec, :auto
config :pincer, :sqlite_vec_dimensions, 1024
config :pincer, :llm_adapter, Pincer.LLM.Client
config :pincer, :tts_adapter, Pincer.LLM.TTS
config :pincer, :cron_adapter, Pincer.Adapters.Cron.Storage
config :pincer, :git_adapter, Pincer.Adapters.Git
config :pincer, :sandbox_adapter, Pincer.Adapters.Sandbox.Local

config :pincer, :sandbox_adapters, %{
  local: Pincer.Adapters.Sandbox.Local,
  docker: Pincer.Adapters.Sandbox.Docker,
  ssh: Pincer.Adapters.Sandbox.SSH
}

config :pincer, :session_registry, Pincer.Core.Session.Registry
config :pincer, :session_adapter, Pincer.Core.Session.Adapter
config :pincer, :ux_adapter, Pincer.Core.UX.Adapter
config :pincer, :project_adapter, Pincer.Core.Project.Adapter
config :pincer, :channel_policy_adapter, Pincer.Core.ChannelPolicy.Adapter
config :pincer, :streaming_adapter, Pincer.Core.Streaming.Adapter
config :pincer, :pubsub_adapter, Pincer.Infra.PubSub
config :pincer, :messaging_adapter, Pincer.Adapters.Messaging.PubSub

config :pincer, :channel_actions_adapters, %{
  telegram: Pincer.Channels.Telegram,
  discord: Pincer.Channels.Discord,
  whatsapp: Pincer.Channels.WhatsApp
}

config :pincer, :attachment_adapter, Pincer.Adapters.AttachmentFetcher
config :pincer, :introspection_skill_generator, Pincer.Core.Skills.Generator

config :pincer, :llm_providers, %{
  "google" => %{
    adapter: Pincer.LLM.Providers.Google,
    env_key: "GOOGLE_API_KEY",
    default_model: "gemini-3.8-flash",
    # Gemini suporta leitura nativa de PDFs e imagens via inlineData.
    supports_files: true
  },
  "openrouter" => %{
    adapter: Pincer.LLM.Providers.OpenRouter,
    env_key: "OPENROUTER_API_KEY",
    default_model: "openrouter/free"
  },
  "anthropic" => %{
    adapter: Pincer.LLM.Providers.Anthropic,
    env_key: "ANTHROPIC_API_KEY",
    default_model: "claude-sonnet-5-5"
  },
  "openai" => %{
    adapter: Pincer.LLM.Providers.OpenAI,
    env_key: "OPENAI_API_KEY",
    default_model: "gpt-6.2-sol"
  },
  "opencode_zen" => %{
    adapter: Pincer.LLM.Providers.OpencodeZen,
    env_key: "OPENCODE_ZEN_API_KEY",
    default_model: "kimi-k2.5-free"
  },
  "z_ai" => %{
    adapter: Pincer.LLM.Providers.Zhipu,
    env_key: "Z_AI_API_KEY",
    default_model: "glm-5.3"
  },
  "z_ai_coding" => %{
    adapter: Pincer.LLM.Providers.Zhipu,
    base_url: "https://api.z.ai/api/coding/paas/v4/chat/completions",
    env_key: "Z_AI_CODING_API_KEY",
    default_model: "glm-5.4"
  },
  "moonshot" => %{
    adapter: Pincer.LLM.Providers.Moonshot,
    env_key: "MOONSHOT_API_KEY",
    default_model: "kimi-k3"
  },
  "moonshot_coding" => %{
    adapter: Pincer.LLM.Providers.Moonshot,
    env_key: "MOONSHOT_CODING_API_KEY",
    default_model: "k3.1-pro"
  },
  "groq" => %{
    adapter: Pincer.LLM.Providers.Groq,
    env_key: "GROQ_API_KEY",
    default_model: "openai/gpt-oss-120b"
  },
  "groq_whisper" => %{
    adapter: Pincer.LLM.Providers.GroqWhisper,
    env_key: "GROQ_API_KEY",
    default_model: "whisper-large-v3-turbo"
  },
  "minimax" => %{
    adapter: Pincer.LLM.Providers.MiniMax,
    env_key: "MINIMAX_API_KEY",
    default_model: "MiniMax-M3.1-Flash"
  },
  "deepseek" => %{
    adapter: Pincer.LLM.Providers.DeepSeek,
    env_key: "DEEPSEEK_API_KEY",
    default_model: "deepseek-v4-flash"
  },
  "qwen" => %{
    adapter: Pincer.LLM.Providers.Qwen,
    env_key: "DASHSCOPE_API_KEY",
    default_model: "qwen3.6-plus"
  },
  "mistral" => %{
    adapter: Pincer.LLM.Providers.Mistral,
    env_key: "MISTRAL_API_KEY",
    default_model: "mistral-large-4"
  },
  "ollama" => %{
    adapter: Pincer.LLM.Providers.Ollama,
    env_key: nil,
    default_model: "qwen3.5:9b"
  }
}

# Runtime default is overridden by config.yaml's llm.provider at startup (see Pincer.Infra.Config.load/0)
config :pincer, :default_llm_provider, "openrouter"

config :pincer, :tool_adapters, [Pincer.Adapters.NativeToolRegistry]

config :pincer, :skills_registry_adapters, %{
  local: Pincer.Adapters.SkillsRegistry.Local,
  clawhub: Pincer.Adapters.SkillsRegistry.ClawHub
}

# Configuração de Logs
config :logger,
  level: :info,
  colors: [enabled: true, info: :cyan, warn: :yellow, error: :red, debug: :magenta]

config :logger, :default_formatter,
  format: {Pincer.Utils.LoggerFormatter, :format},
  metadata: [:session_id, :project_id, :module]

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
config :pincer, :tool_max_concurrency, 10

# Delegated sub-agents
config :pincer, :max_subagents, 32
config :pincer, :max_subagents_per_session, 8
config :pincer, :max_subagent_depth, 2
config :pincer, :max_subagent_tree_tokens, 200_000
config :pincer, :max_subagent_tree_ms, 1_800_000

# Curated memory character budgets (MEMORY.md / USER.md)
config :pincer, :curated_memory_limits, %{memory: 4_000, user: 2_500}

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
