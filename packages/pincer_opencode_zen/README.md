# pincer_opencode_zen

Opencode Zen LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_opencode_zen, "~> 0.2"}
  ]
end
```

## Usage

Set `OPENCODE_ZEN_API_KEY` in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "opencode_zen"
  opencode_zen:
    base_url: "https://opencode.ai/zen/v1/chat/completions"
    default_model: "kimi-k2.5-free"
```

### Recommended Models & Gateway Notes (late 2026)

- **Default gateway model:** `kimi-k2.5-free` (managed via `opencode.ai/console/models`).
- **High-volume BYOK fallback:** Pair `opencode_zen` with `openrouter` (`openrouter/free`, `google/gemma-4-31b-it:free`), `google` (`gemini-3.8-flash`), `groq` (`openai/gpt-oss-120b`), or local `ollama` (`qwen3.5:9b`) to avoid rotating free-tier window caps.
- See [Opencode Zen Setup](../../docs/OPENCODE_ZEN_SETUP.md) for details.

## License

MIT
