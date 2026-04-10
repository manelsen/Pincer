# pincer_openai

OpenAI LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_openai, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
llm:
  provider: openai
  openai:
    api_key: $OPENAI_API_KEY
    model: gpt-4o
```

## License

MIT
