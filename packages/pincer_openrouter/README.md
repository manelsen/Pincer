# pincer_openrouter

OpenRouter LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_openrouter, "~> 0.1"}
  ]
end
```

## Usage

Set `OPENROUTER_API_KEY` in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "openrouter"
  openrouter:
    base_url: "https://openrouter.ai/api/v1/chat/completions"
    default_model: "openrouter/free"
```

### Recommended Models (late 2026)

| Category | Model ID | Notes |
|---|---|---|
| Auto-Free Router (Default) | `openrouter/free` | Routes automatically across active `:free` models |
| Free Vision + Text | `google/gemma-4-31b-it:free` | Strong open-weights multimodal model (`262K` context) |
| Free Long Reasoning | `nvidia/nemotron-3.5-lightning:free` | Up to `1M` context for multi-step reasoning |
| Free Agentic Coding | `cohere/north-mini-code:free` | Focused on code edits and tool calling |
| Cloud Flagships | `anthropic/claude-sonnet-5-5`, `google/gemini-3.8-flash`, `openai/gpt-6.2-sol` | Paid high-reliability routing |
| Embeddings (1024d SQLite default) | `baai/bge-m3` (`baai/bge-large-en-v1.5` fallback) | Used by `Pincer.LLM.Client.generate_embedding/2` |

## License

MIT
