# pincer_mistral

Mistral AI LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_mistral, "~> 0.1"}
  ]
end
```

## Usage

Set `MISTRAL_API_KEY` in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "mistral"
  mistral:
    default_model: "mistral-large-4"
```

### Recommended Models (late 2026)

| Tier | Model ID | Notes |
|---|---|---|
| Flagship (Default) | `mistral-large-4` | `1M` context window with built-in reasoning |
| General & Vision | `mistral-small-4` | Fast multimodal and reasoning tasks |
| Code Specialist | `codestral` | Dedicated code generation and FIM completion |
| Edge / Compact | `ministral-3-3b` | Low-latency lightweight workloads |

## License

MIT
