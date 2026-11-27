# pincer_ollama

Ollama LLM provider adapter for the Pincer AI agent framework.

Part of the [Pincer](https://github.com/manelsen/Pincer) AI agent framework.

## Installation

```elixir
def deps do
  [
    {:pincer_ollama, "~> 0.2"}
  ]
end
```

## Usage

Run an Ollama daemon (`ollama serve`) and add to your `config.yaml` (no API key required; override endpoint via `OLLAMA_BASE_URL` if non-local):

```yaml
llm:
  provider: "ollama"
  ollama:
    base_url: "http://localhost:11434"
    default_model: "qwen3.5:9b"
```

### Recommended Local Models by Hardware (late 2026)

| Hardware / VRAM | Model Tag | Notes |
|---|---|---|
| 8 GB VRAM / Lightweight | `qwen3.5:4b`, `gemma3n` | Fast interactive chat on constrained GPUs |
| 12–16 GB VRAM (Default) | `qwen3.5:9b`, `gemma4:12b` | Best local balance of chat, vision, and tool calling |
| 24 GB VRAM (`3090`/`4090`) | `qwen3.8:27b`, `qwen3-coder:30b` | Strong local coding and deep reasoning |
| High-Memory MoE | `qwen3.6:35b-a3b` | Sparse MoE routing for low active-parameter latency |

### Adapter Notes
- Pairs with Pincer's introspection locality guard (`follow_session` / `local_only`), keeping reflection traces local when chatting with Ollama.

## License

MIT
