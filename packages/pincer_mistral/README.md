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

Add to your `config.yaml`:

```yaml
llm:
  provider: mistral
  mistral:
    api_key: $MISTRAL_API_KEY
    model: mistral-large-latest
```

## License

MIT
