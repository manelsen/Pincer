# pincer_google

Google Gemini LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_google, "~> 0.2"}
  ]
end
```

## Usage

Set `GOOGLE_API_KEY` in `.env` and add to your `config.yaml`:

```yaml
llm:
  provider: "google"
  google:
    default_model: "gemini-3.8-flash"
```

### Recommended Models (late 2026)

| Tier | Model ID | Notes |
|---|---|---|
| Frontier Reasoning | `gemini-4-carbon` | Complex engineering, scientific, and multimodal reasoning |
| Flagship Multimodal | `gemini-4-argon` | General-purpose flagship multimodal assistant |
| Balanced Daily Driver | `gemini-4-hydrogen` | Everyday coding and agentic tool loops |
| Fast Production (Default) | `gemini-3.8-flash` | Low-latency, high-efficiency general assistant |
| Ultra-Lite | `gemini-3.5-flash-lite` | High-throughput summarization and routing |

### Adapter Notes
- Supports native inline PDFs and images (`supports_files: true` in `config/config.exs`).
- Discovers `generateContent`-capable models via `GET /v1beta/models` and falls back to current Gemini 3.8 / 4 IDs when no key is set.

## License

MIT
