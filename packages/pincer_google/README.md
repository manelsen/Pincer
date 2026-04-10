# pincer_google

Google Gemini LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_google, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
llm:
  provider: google
  google:
    api_key: $GOOGLE_API_KEY
    model: gemini-2.0-flash
```

## License

MIT
