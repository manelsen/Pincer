# pincer_qwen

Alibaba Cloud Qwen (DashScope) LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_qwen, "~> 0.1"}
  ]
end
```

## Usage

Add to your `config.yaml`:

```yaml
llm:
  provider: qwen
  qwen:
    api_key: $DASHSCOPE_API_KEY
    model: qwen-max
```

## License

MIT
