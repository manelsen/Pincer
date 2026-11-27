# pincer_zhipu

Z.AI (Zhipu GLM) LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_zhipu, "~> 0.2"}
  ]
end
```

## Usage

Set `Z_AI_API_KEY` (and optionally `Z_AI_CODING_API_KEY` for `z_ai_coding`) in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "z_ai"
  z_ai:
    base_url: "https://api.z.ai/api/coding/paas/v4/chat/completions"
    default_model: "glm-5.3"
```

### Recommended Models (late 2026)

| Tier | Model ID | Notes |
|---|---|---|
| Coding Plan Flagship (`z_ai_coding`) | `glm-5.4` | Loop-transformer coding architecture for coding plans |
| General & Agentic Flagship (Default) | `glm-5.3` | `1M` context window for reasoning, coding, and tool calls |
| Fast / Multimodal | `glm-5.3-flash`, `glm-5v-turbo` | Low-latency UI and multimodal vision tasks |

## License

MIT
