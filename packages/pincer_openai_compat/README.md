# pincer_openai_compat

Base OpenAI-compatible HTTP adapter for the Pincer AI agent framework — shared implementation used by `pincer_openai`, `pincer_groq`, `pincer_mistral`, `pincer_moonshot`, `pincer_minimax`, `pincer_openrouter`, `pincer_deepseek`, `pincer_qwen`, `pincer_zhipu`, and `pincer_opencode_zen`.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_openai_compat, "~> 0.1"}
  ]
end
```

## Usage

This package is a shared base and is typically pulled in automatically as a dependency of a concrete provider package. Configure the specific provider instead:

```yaml
llm:
  provider: openai
  openai:
    api_key: $OPENAI_API_KEY
    model: gpt-4o
```

To build a custom OpenAI-compatible provider, depend on this package and delegate to `Pincer.OpenaiCompat.Client`.

## License

MIT
