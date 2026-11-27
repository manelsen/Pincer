# pincer_deepseek

DeepSeek LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_deepseek, "~> 0.2"}
  ]
end
```

## Usage

Set `DEEPSEEK_API_KEY` in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "deepseek"
  deepseek:
    default_model: "deepseek-v4-flash"
```

### Recommended Models (late 2026)

| Tier | Model ID | Notes |
|---|---|---|
| Fast Multimodal (Default) | `deepseek-v4-flash` | High-efficiency V4 model (`deepseek-flash` alias) |
| Heavy Reasoning & Coding | `deepseek-v4-pro` | Flagship reasoning and complex engineering model |

## License

MIT
