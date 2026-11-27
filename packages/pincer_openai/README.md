# pincer_openai

OpenAI LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_openai, "~> 0.2"}
  ]
end
```

## Usage

Set `OPENAI_API_KEY` in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "openai"
  openai:
    default_model: "gpt-6.2-sol"
```

### Recommended Models (late 2026)

| Purpose | Model ID | Notes |
|---|---|---|
| Flagship Reasoning & Coding | `gpt-6.2-astra` | Complex end-to-end reasoning and heavy agentic tasks |
| Balanced Daily Driver (Default) | `gpt-6.2-sol` | High performance with balanced latency and cost |
| Visual / Computer Use | `gpt-6.1-terra` | UI comprehension, computer-use, and structured output |
| Fast Routing | `gpt-6-luna` | High-volume, low-latency sub-tasks |
| Text-to-Speech (`Pincer.LLM.TTS`) | `tts-1`, `tts-1-hd`, `gpt-4o-mini-tts` | Speech synthesis voices (`alloy`, `ash`, `coral`, `nova`, `sage`) |

## License

MIT
