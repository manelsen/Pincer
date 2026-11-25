defmodule Pincer.Adapters do
  @moduledoc "Registry and umbrella for all Adapters."
  use Boundary,
    deps: [Pincer.Core, Pincer.Ports, Pincer.Infra, Pincer.Utils],
    check: [
      apps: [
        :pincer_anthropic,
        :pincer_cli,
        :pincer_deepseek,
        :pincer_dingtalk,
        :pincer_discord,
        :pincer_feishu,
        :pincer_google,
        :pincer_groq,
        :pincer_line,
        :pincer_minimax,
        :pincer_mistral,
        :pincer_moonshot,
        :pincer_ollama,
        :pincer_openai,
        :pincer_openai_compat,
        :pincer_opencode_zen,
        :pincer_openrouter,
        :pincer_ports,
        :pincer_qwen,
        :pincer_shared,
        :pincer_slack,
        :pincer_telegram,
        :pincer_webhook,
        :pincer_whatsapp,
        :pincer_zhipu
      ]
    ],
    exports: [Storage.SQLite, Storage.Checkpoint, Storage.MemoryHelpers]
end
