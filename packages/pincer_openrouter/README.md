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

Add to your `config.yaml`:

```yaml
llm:
  provider: openrouter
  openrouter:
    api_key: $OPENROUTER_API_KEY
    model: anthropic/claude-3.5-sonnet
```

## License

MIT
