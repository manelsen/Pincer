# pincer_groq

Groq LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_groq, "~> 0.2"}
  ]
end
```

## Usage

Set `GROQ_API_KEY` in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "groq"
  groq:
    base_url: "https://api.groq.com/openai/v1/chat/completions"
    default_model: "openai/gpt-oss-120b"
```

### Recommended Models (late 2026)

| Purpose | Model ID | Notes |
|---|---|---|
| General Chat & Tools (Default) | `openai/gpt-oss-120b` | High-capability open-weights model on Groq LPU |
| Fast Introspection / Routing | `openai/gpt-oss-20b`, `llama-3.1-8b-instant` | Ultra-low latency for reflection and router tiers |
| Qwen / Llama Open-Weights | `qwen/qwen3.8-27b`, `llama-3.3-70b-versatile` | Strong multilingual reasoning and tool execution |
| Speech Transcription (`GroqWhisper`) | `whisper-large-v3-turbo` | Audio-to-text endpoint via `groq_whisper` |

## License

MIT
