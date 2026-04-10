# pincer_ollama

Ollama LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_ollama, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
llm:
  provider: ollama
  ollama:
    base_url: http://localhost:11434
    model: llama3.2
```

## License

MIT
