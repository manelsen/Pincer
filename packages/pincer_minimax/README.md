# pincer_minimax

MiniMax AI LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_minimax, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
llm:
  provider: minimax
  minimax:
    api_key: $MINIMAX_API_KEY
    model: MiniMax-Text-01
```

## License

MIT
