# SPECS — Pincer Subsystems

## Environment Variables & API Keys

Each LLM provider requires its own API key set as an environment variable.
The system resolves the key at runtime via the provider's `env_key` setting
(defined in `config/config.exs` under `:llm_providers`).

### Required keys per provider

| Provider | Env Variable | Used by default? |
|----------|-------------|-----------------|
| `google` | `GOOGLE_API_KEY` | No |
| `openrouter` | `OPENROUTER_API_KEY` | Yes (fallback) |
| `opencode_zen` | `OPENCODE_ZEN_API_KEY` | Yes (fallback) |
| `z_ai` | `Z_AI_API_KEY` | Yes (introspection + balanced tier) |
| `z_ai_coding` | `Z_AI_CODING_API_KEY` | Yes (default provider + powerful tier) |
| `moonshot` | `MOONSHOT_API_KEY` | No |
| `groq` | `GROQ_API_KEY` | Yes (local/fast tiers) |
| `minimax` | `MINIMAX_API_KEY` | No |

### Minimal setup

To run with introspection + model router + default provider:

```
Z_AI_API_KEY=...          # introspection + model router balanced tier
Z_AI_CODING_API_KEY=...   # default LLM provider + model router powerful tier
GROQ_API_KEY=...          # model router local/fast tiers
TELEGRAM_BOT_TOKEN=...    # if Telegram channel enabled
```

Copy `.env.example` to `.env` and fill in the keys for providers you use.

### Database overrides

Optional env vars can override `config.yaml` database settings:

```
PINCER_DB_HOST, PINCER_DB_PORT, PINCER_DB_USER, PINCER_DB_PASSWORD,
PINCER_DB_NAME, PINCER_DB_POOL_SIZE, PINCER_DB_SSL
```

---

## Subsystems

### 1. Session Pruner (`Pincer.Core.Session.Pruner`)

Replaces old tool results in conversation history with compact summaries
to reduce token bloat. Integrated into `PromptAssembly.prepare/3`.

```elixir
# Default: keep last 6 messages intact, summarize older tool results
Pruner.prune(history)
# Custom window
Pruner.prune(history, keep_recent: 10)
```

### 2. Model Router (`Pincer.Core.LLM.ModelRouter`)

Scores request complexity (0.0–1.0) and routes to a tiered provider/model.
Controlled by `config.yaml` → `model_router` section.

```elixir
{:ok, :balanced, "z_ai", "glm-4.7"} = ModelRouter.route(history)
{:ok, :default} = ModelRouter.route(history)  # when disabled
```

Tier thresholds: `local < 0.25`, `fast < 0.45`, `balanced < 0.65`, `powerful >= 0.65`.

Scoring factors: tool calls (0.30), technical content (0.30), conversation depth (0.20),
last message length (0.20).

**Important:** each tier's provider must have its API key set in `.env`. If a key is
missing the LLM client will fail on that tier. Set `model_router.enabled: false` in
`config.yaml` to disable routing.

### 3. Command Queue (`Pincer.Core.Session.CommandQueue`)

Stateful message queue with three modes replacing the simple debounce buffer.

| Mode | Behavior |
|------|----------|
| `:collect` | Buffer messages, flush on drain (agent idle) |
| `:steer` | Flush immediately on every push (interrupt agent) |
| `:followup` | Hold until explicit drain (next-turn queueing) |

```elixir
q = CommandQueue.new(:collect)
{:ok, q} = CommandQueue.push(q, "hello")
{messages, q} = CommandQueue.drain(q)
```

### 4. Heartbeat Contract Engine (`Pincer.Core.Heartbeat.ContractEngine`)

ETS-backed promise tracking for proactive agent accountability. Agents record
promises during turns; heartbeat pulses evaluate expiration.

```elixir
:ok = ContractEngine.make_promise("agent_1", "Monitor repo X", deadline: future)
results = ContractEngine.evaluate("agent_1")  # [{:expired | :pending, promise}]
pending = ContractEngine.pending("agent_1")
:ok = ContractEngine.fulfill("agent_1", promise_id)
```

### 5. Skills Manifest (`Pincer.Core.Skills.Manifest` + `Loader`)

Skills defined as markdown with YAML frontmatter, loaded from three tiers:
workspace > shared > bundled.

```markdown
---
name: web-search
version: "1.0.0"
description: Search the web
requirements:
  - binary: curl
provides:
  - tool: search_web
    description: Search the web for a query
---
# Instructions...
```

```elixir
skills = Loader.discover(bundled: "priv/skills", shared: "~/.pincer/skills",
                         workspace: "workspaces/agent/.pincer/skills")
issues = Loader.check_requirements(skills |> hd())
```

### 6. Consciousness Kernel (`Pincer.Core.Kernel`)

Per-agent GenServer with configurable tick loop for introspection and
self-reflection. Requires the `introspection` section in `config.yaml`
with a valid provider and model.

```yaml
introspection:
  provider: "z_ai"
  model: "glm-4.7"
  max_tokens: 512
  temperature: 0.7
```

**Important:** the `Z_AI_API_KEY` (or whichever provider is configured) must be
set in `.env` for introspection to work. If missing, reflection will time out
with a warning and the kernel continues operating normally.

### 7. Bootstrap Ritual

New agents start without IDENTITY/SOUL files. The bootstrap ritual is triggered
on first interaction via `BOOTSTRAP.md`, which drives an LLM conversation to
form the agent's personality. Previously these files were pre-seeded, preventing
the ritual from ever firing.
