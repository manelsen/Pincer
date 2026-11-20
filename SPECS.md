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

### 8. Embedding Generation

Semantic memory and graph indexing use `Pincer.LLM.Client.generate_embedding/2`.

- If the caller does not pass `:model`, the client resolves `config[:embedding_model]`
  first.
- For `openrouter`, the default embedding model remains `baai/bge-m3`.
- If OpenRouter returns the router-side error `No successful provider responses.`
  for `baai/bge-m3`, the client retries once with `baai/bge-large-en-v1.5`.
- Both default and fallback models are 1024-dimensional, preserving pgvector
  column compatibility for the current HNSW indexes.

### 9. Execution Context & Correlated Outcomes (`Pincer.Core.Executor.Ctx`, `Pincer.Core.TaskSupervisor`)

`Pincer.Core.Executor` threads an explicit immutable `%Pincer.Core.Executor.Ctx{}`
struct across every step (loop guard, prompt assembly, stream accumulation,
tool execution, trace emission), removing process-dictionary dependency injection.

- `Executor.run/4` executes the loop without side-channel duplicate emissions,
  normalizes `Usage`, emits the trace checkpoint/snapshot once, optionally notifies
  `session_pid` once (`notify?: true` default, tagged with `ref` when provided),
  and returns `{:ok, final_history, final_content, usage}` or `{:error, reason}`
  directly to its caller.
- Callers (`Session.Server`, `Project.Server`, `Orchestration.SubAgent`, and
  unsolicited Blackboard/bootstrap evaluations) spawn supervised tasks via
  `Task.Supervisor.async_nolink(Pincer.Core.TaskSupervisor, ...)` with
  `notify?: false` and correlate `{ref, result}` and `{:DOWN, ref, ...}` messages
  strictly by monitor reference.

### 10. Session Decomposition (`Session.History`, `Session.Approval`, `Session.Blackboard`, `PromptAssembly`)

`Pincer.Core.Session.Server` delegates non-GenServer concerns to focused modules:

- `Pincer.Core.PromptAssembly` builds the base system prompt (`build_system_prompt/1`,
  `bootstrap_active?/2`) and prepares/prunes LLM prompt histories (`prepare/3`).
- `Pincer.Core.Session.History` owns transcript loading, user/assistant persistence,
  reset snapshots, sliding-window pruning, system prompt hot-swap, and workspace
  file reference resolution.
- `Pincer.Core.Session.Approval` owns approval parsing, TTL auto-approval, and
  pending approval state transitions.
- `Pincer.Core.Session.Blackboard` owns Blackboard progress ingestion, journal
  formatting, and pure LLM evaluation of unsolicited updates (`evaluate_update/3`).

### 11. Parameterized Registry (`Pincer.Core.Registry`)

`Pincer.Core.Registry` is a single parameterized registry wrapper supporting both
`:horde` (default, cluster-wide via `Horde.Registry`) and `:local` (via Elixir
`Registry`) backends with `keys: :unique`, replacing per-domain registry wrappers.

### 12. Boundary Normalization (`Pincer.Infra.Config`, `Pincer.Core.Structs.Usage`)

External payloads are normalized once at ingestion boundaries:

- `Pincer.Infra.Config.load_file/1` and `normalize_keys/1` convert YAML and merged
  configuration keys to canonical `snake_case` strings at load time (preserving
  structs and uppercase env-var keys), eliminating camelCase/snake_case dual lookups.
- `Pincer.Core.Structs.Usage` defines `%Usage{prompt_tokens, completion_tokens, total_tokens}`
  normalized once at `Pincer.LLM.Client`, `Executor`, and `Session.Preferences` boundaries.
- `model_override` is normalized to atom-keyed maps (`%{provider: ..., model: ...}`).

### 13. Channel-Owned Formatting (`Pincer.Channels.Telegram.ResponseEnvelope`)

Telegram HTML usage-footer formatting and reasoning delivery options reside in
`Pincer.Channels.Telegram.ResponseEnvelope` inside `packages/pincer_telegram`,
keeping `Pincer.Core` transport-agnostic (plain text + structured `%Usage{}`).

