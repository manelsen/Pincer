# pincer_groq

Groq LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_groq, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
llm:
  provider: groq
  groq:
    api_key: $GROQ_API_KEY
    model: llama-3.3-70b-versatile
```

## License

MIT
