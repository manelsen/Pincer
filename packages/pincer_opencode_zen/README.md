# pincer_opencode_zen

Opencode Zen LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_opencode_zen, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
llm:
  provider: opencode_zen
  opencode_zen:
    api_key: $OPENCODE_ZEN_API_KEY
    model: zen-1
```

## License

MIT
