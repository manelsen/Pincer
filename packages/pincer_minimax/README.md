# pincer_minimax

MiniMax AI LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_minimax, "~> 0.2"}
  ]
end
```

## Usage

Set `MINIMAX_API_KEY` (and optionally `MINIMAX_GROUP_ID`) in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "minimax"
  minimax:
    default_model: "MiniMax-M3.1-Flash"
```

### Recommended Models (late 2026)

| Tier | Model ID | Notes |
|---|---|---|
| Fast Coding & Multimodal (Default) | `MiniMax-M3.1-Flash` | `1M` context window with adjustable thinking depth |
| Base Flagship | `MiniMax-M3` | `1M` max context (`512K` minimum guarantee) |

## License

MIT
