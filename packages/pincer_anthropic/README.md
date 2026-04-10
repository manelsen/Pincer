# pincer_anthropic

Anthropic (Claude) LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_anthropic, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
llm:
  provider: anthropic
  anthropic:
    api_key: $ANTHROPIC_API_KEY
    model: claude-opus-4-5
```

## License

MIT
