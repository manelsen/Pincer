# pincer_deepseek

DeepSeek LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_deepseek, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
llm:
  provider: deepseek
  deepseek:
    api_key: $DEEPSEEK_API_KEY
    model: deepseek-chat
```

## License

MIT
