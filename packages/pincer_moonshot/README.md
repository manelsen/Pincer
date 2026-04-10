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

Add to your `config.yaml`:

```yaml
llm:
  provider: moonshot
  moonshot:
    api_key: $MOONSHOT_API_KEY
    model: moonshot-v1-8k
```

## License

MIT
