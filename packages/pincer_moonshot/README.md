# pincer_moonshot

Moonshot (Kimi) LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_moonshot, "~> 0.1"}
  ]
end
```

## Usage

Set `MOONSHOT_API_KEY` (or `MOONSHOT_CODING_API_KEY` for `moonshot_coding`) in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "moonshot"
  moonshot:
    base_url: "https://api.moonshot.ai/v1/chat/completions"
    default_model: "kimi-k3"
```

### Recommended Models (late 2026)

| Tier | Model ID | Notes |
|---|---|---|
| Coding Flagship (`moonshot_coding`) | `k3.1-pro` | `1M` context MoE tailored for complex coding agents |
| Foundational Reasoning (Default) | `kimi-k3` | `1M` context with native vision and reasoning |
| Shorter-Context / Specialized | `k3-256k`, `kimi-k2.7-code` | Fast coding and `256K` budget workloads |

### Adapter Notes
- Automatically clamps `temperature` into `[0.0, 1.0]` and supports `thinking: false` for instant mode.

## License

MIT
