# pincer_anthropic

Anthropic (Claude) LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_anthropic, "~> 0.2"}
  ]
end
```

## Usage

Set `ANTHROPIC_API_KEY` in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "anthropic"
  anthropic:
    default_model: "claude-sonnet-5-5"
```

### Recommended Models (late 2026)

| Tier | Model ID | Notes |
|---|---|---|
| Deep Reasoning / Long-Horizon | `claude-fable-5-2` | Demanding reasoning and multi-step agentic workflows |
| Heavy Agentic Coding | `claude-opus-5-5` | Complex software engineering and deep codebase work |
| Balanced (Default) | `claude-sonnet-5-5` | Best speed/intelligence balance (`1M` context) |
| Fast / High-Volume | `claude-haiku-5-5` | Low-latency classification, routing, and sub-agents |

### Adapter Notes
- Uses the native Messages API (`https://api.anthropic.com/v1/messages`) with SSE streaming and `thinking_level` (`low` / `medium` / `high`) budget tokens.
- Discovers models dynamically via `GET /v1/models` and falls back to the Claude 5.5 / Fable 5.2 defaults offline.

## License

MIT
