# pincer_qwen

Alibaba Cloud Qwen (DashScope) LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_qwen, "~> 0.2"}
  ]
end
```

## Usage

Set `DASHSCOPE_API_KEY` in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "qwen"
  qwen:
    default_model: "qwen3.6-plus"
```

### Recommended Models (late 2026)

| Tier | Model ID | Notes |
|---|---|---|
| Flagship Reasoning | `qwen3.7-max` | Top-tier reasoning with `1M` context window |
| Balanced Production (Default) | `qwen3.6-plus` | Workhorse for agentic tool use (`1M` context) |
| Low-Cost / High-Speed | `qwen3.6-flash` | High-throughput latency-sensitive workloads |
| Multimodal Vision | `qwen3-vl-plus` | Vision-language understanding |

## License

MIT
