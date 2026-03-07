import Config

config :pincer,
  ecto_repos: [Pincer.Infra.Repo]

config :telegex,
  token: System.get_env("TELEGRAM_BOT_TOKEN"),
  caller_adapter: {Finch, [name: Pincer.Finch]}

config :pincer, :storage_adapter, Pincer.Storage

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
    default_model: "openrouter/free"
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
  }
}

config :pincer, :default_llm_provider, "openrouter"

# Configuração de Logs
config :logger,
  level: :info,
  colors: [enabled: true, info: :cyan, warn: :yellow, error: :red, debug: :magenta]

config :logger, :console,
  format: {Pincer.Utils.LoggerFormatter, :format},
  metadata: [:session_id, :project_id, :module]

# Handlers de log (Console e Arquivo)
config :logger, :handlers, [
  %{
    id: :file_log,
    module: :logger_std_h,
    config: %{
      type: {:file, ~c"logs/server.log"},
      max_no_bytes: 10_000_000,
      max_no_files: 5,
      compress_on_rotate: true
    }
  }
]

config :pincer, Pincer.Infra.Repo, log: false

config :pincer, :webhook_token, System.get_env("PINCER_WEBHOOK_TOKEN", "")

config :pincer, :log_mcp, false

config :nostrum,
  token: System.get_env("DISCORD_BOT_TOKEN") || "DISCORD_TOKEN_REQUIRED_FOR_CHANNEL",
  gateway_intents: [:guild_messages, :message_content, :direct_messages]

import_config "#{config_env()}.exs"
