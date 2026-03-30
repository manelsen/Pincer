# Pincer

Autonomous AI agents on the BEAM — OTP supervision, multi-channel messaging, MCP tool integration, and provider-agnostic LLM access with automatic failover.

**What it does**: Pincer is an Elixir/OTP framework that runs persistent AI agents. Each agent gets a supervised GenServer session, can use 80+ tool actions across 21 built-in tool modules, talks to humans through Telegram/Discord/CLI/webhook, and remembers conversations across restarts using a tiered memory system backed by PostgreSQL + pgvector.

**Who it's for**: Developers building long-running AI assistants that need fault tolerance, multi-channel presence, and structured memory — without babysitting.

**Who it's not for**: If you need a stateless chatbot wrapper, a single-function-call orchestrator, or something that runs in a Lambda, Pincer is more infrastructure than you need.

---

## Quickstart

```bash
git clone https://github.com/micelio/pincer.git && cd pincer
cp .env.example .env
# Set at least one LLM provider key in .env
docker compose up --build -d
docker compose exec pincer-server mix pincer.chat
```

That's it. You're talking to an agent. The Docker build starts PostgreSQL with pgvector, runs migrations, and boots the Pincer supervision tree.

To run locally instead:

```bash
docker compose up -d postgres    # just the database
mix deps.get
mix ecto.create && mix ecto.migrate
mix pincer.chat                   # interactive CLI agent
```

## Requirements

| Dependency | Minimum Version | Why |
|---|---|---|
| Elixir | 1.14+ | Compilation target |
| Erlang/OTP | 27+ | `boundary` compiler plugin |
| PostgreSQL | 18+ with pgvector | Graph memory + message storage |
| Node.js | 18+ | MCP sidecar servers (optional) |

## Configuration

Runtime config lives in `config.yaml`, not `config/*.exs`. The `Pincer.Infra.Config` module loads it at startup. Edit `config.yaml` to configure:

- **LLM providers** — set `llm.provider` and add API keys to `.env`
- **Channels** — enable/disable Telegram, Discord, CLI, webhook, WhatsApp, LINE
- **MCP servers** — add external tool servers under `mcp.servers`
- **Database** — override via `config.yaml` or `PINCER_DB_*` env vars
- **Workspace isolation** — `tools.restrict_to_workspace: true` (default) confines file/shell tools to the agent's workspace

### LINE Messaging API

```yaml
# config.yaml
channels:
  line:
    enabled: true
    adapter: "Pincer.Channels.Line"
    token_env: "LINE_CHANNEL_ACCESS_TOKEN"
    secret_env: "LINE_CHANNEL_SECRET"
```

Set `LINE_CHANNEL_ACCESS_TOKEN` and `LINE_CHANNEL_SECRET` in `.env`.

## Architecture

Pincer uses **Hexagonal Architecture** (Ports & Adapters) with compile-time boundary enforcement. Dependencies flow inward — outer layers can depend on inner, never the reverse:

```
Channels       Telegram, Discord, Slack, WhatsApp, LINE, CLI, Webhook
    ↓
Adapters       Concrete implementations: MCP, Cron, Tools
    ↓
Core           Domain logic: Executor, Session, Orchestration, Memory
    ↓
Ports          Behaviour contracts (LLM, Storage, Channel, Tool)
    ↓
Infra          PubSub, Config, Ecto Repo
```

The `boundary` compiler plugin enforces this at compile time. `mix compile --warnings-as-errors` will fail if an inner layer reaches outward.

### Supervision Tree

Every component is supervised. If the LLM client crashes, it restarts. If a user session dies, it restarts — without losing the rest of the tree.

```
Pincer.Supervisor (one_for_one)
├── Infra.PubSub
├── Finch                       HTTP connection pool
├── Infra.Repo                  Ecto/PostgreSQL
├── Heartbeat                   Health checks + GitHub watcher
├── Dispatcher.Registry         Message dispatcher
├── MCP.Supervisor              DynamicSupervisor for MCP servers
│   └── MCP.Manager             Lifecycle + tool discovery
├── Session.Registry            Active sessions (unique per user)
├── Session.Supervisor          DynamicSupervisor for user sessions
├── Cron.Scheduler              Persistent scheduled jobs
├── Channels.Supervisor         One SessionSupervisor per enabled channel
└── Reloader                    Hot code reloading (dev only)
```

### The Executor (agentic loop)

The core of Pincer is `Pincer.Core.Executor` — a recursive reasoning loop:

1. **Assemble prompt** — injects identity, soul, user profile, communication style, session history, and memory recall
2. **Call LLM** — dispatches to the configured provider via `LLM.Client`
3. **Process response** — if the LLM requests tool calls, execute them and recurse
4. **Deliver** — stream partial tokens to the channel, deliver final response
5. **Consolidate** — archivist extracts knowledge graph entries from the session

The loop has a max recursion depth of 25. Each turn resolves tools from the native registry plus any MCP-discovered tools, so the LLM sees a unified tool surface regardless of origin.

### The Blackboard (inter-agent communication)

`Pincer.Core.Orchestration.Blackboard` is a tiered event store:

- **Hot tier**: ETS table in RAM for recent messages (auto-pruned at 95% capacity)
- **Cold tier**: append-only disk journal for durability across restarts

Agents post scoped messages (per-session, per-project, or global). A nil scope returns only global messages, preventing cross-session leakage. Sub-agents spawned by the orchestrator communicate through the blackboard, not direct messages.

### Memory System

Three layers, each serving a different recall horizon:

| Layer | Storage | Purpose |
|---|---|---|
| **Session** | `HISTORY.md` | Rolling log of the current session |
| **Curated** | `MEMORY.md` | Consolidated insights extracted by the Archivist |
| **Semantic** | PostgreSQL nodes/edges + pgvector | Structured knowledge graph: bugs, decisions, patterns, people, entities |

Before each LLM call, `MemoryRecall` searches all three layers and injects relevant context into the prompt. Memory content is sanitized to prevent prompt injection.

The **Archivist** runs after each session turn and extracts structured knowledge — bug fixes, architectural decisions, code patterns, people, animals, and entity relationships — storing them as typed nodes and edges in the graph.

## Channels

Each channel implements the `Pincer.Ports.Channel` behaviour and uses the injected `__using__` macro for PubSub-driven session callbacks. To add a new channel, implement the behaviour and override the callbacks you need (`on_agent_response`, `on_agent_partial`, `on_agent_error`, etc.) — the rest default to no-ops.

| Channel | Module | Notes |
|---|---|---|
| CLI | `Pincer.Channels.CLI` | Enabled by default in config |
| Telegram | `Pincer.Channels.Telegram` | Requires `TELEGRAM_BOT_TOKEN` |
| Discord | `Pincer.Channels.Discord` | Requires `DISCORD_BOT_TOKEN` |
| Slack | `Pincer.Channels.Slack` | Requires Slack app credentials |
| WhatsApp | `Pincer.Channels.WhatsApp` | Requires Go bridge binary |
| LINE | `Pincer.Channels.Line` | Requires `LINE_CHANNEL_ACCESS_TOKEN` + `LINE_CHANNEL_SECRET` |
| Webhook | `Pincer.Channels.Webhook` | Generic HTTP endpoint |

### Multi-agent routing (Telegram)

One Telegram bot can route different DM users to different agents:

```yaml
# config.yaml
channels:
  telegram:
    agent_map:
      "123456": "annie"
      "789012": "lucie"
```

Each agent gets an isolated workspace at `workspaces/<agent_id>/.pincer/`. Dynamic pairing via `/pair <code>` is also supported.

## LLM Providers

14 providers, all implementing the `Pincer.LLM.Provider` behaviour. The `LLM.Client` dispatches to the configured adapter and handles retry/failover transparently.

| Provider | Module | Notes |
|---|---|---|
| OpenAI-compatible | `Providers.OpenAICompat` | Base adapter for most providers |
| Google Gemini | `Providers.Google` | Native file support (PDF, images) |
| Anthropic | `Providers.Anthropic` | |
| OpenRouter | `Providers.OpenRouter` | |
| Groq | `Providers.Groq` | |
| Groq Whisper | `Providers.GroqWhisper` | Audio transcription |
| Ollama | `Providers.Ollama` | Local models |
| Mistral | `Providers.Mistral` | |
| DeepSeek | `Providers.DeepSeek` | |
| Moonshot | `Providers.Moonshot` | |
| Zhipu | `Providers.Zhipu` | |
| Qwen | `Providers.Qwen` | |
| Minimax | `Providers.Minimax` | |
| OpenCode Zen | `Providers.OpencodeZen` | |

## Built-in Tools

21 tool modules with ~80 actions, all implementing the `Pincer.Ports.Tool` behaviour (`spec/0` + `execute/1` or `execute/2`). MCP-discovered tools merge into the same surface at runtime.

| Tool | Capabilities |
|---|---|
| `file_system` | List and read files within workspace |
| `safe_shell` | Shell execution with approval workflow |
| `web` | Fetch and extract web content |
| `web_visibility` | Check URL visibility and status |
| `github` | Repos, PRs, issues, comments, code search, commits |
| `git_inspect` | Status, diff, log, blame, branches, show, stash |
| `browser` | Headless browser automation |
| `scheduler` / `timer` | Cron jobs and delayed reminders |
| `orchestrator` | Sub-agent dispatch |
| `graph_memory` | Semantic memory CRUD via graph storage |
| `media` | Audio transcription and media handling |
| `config` | Runtime configuration read/write |
| `channel_actions` | Cross-channel actions |
| `external_knowledge` | External knowledge retrieval |
| `learning` | User preference and knowledge capture |
| `workflow` | Multi-step workflow orchestration |
| `code_skeleton` | Code structure analysis |

## MCP Integration

MCP (Model Context Protocol) servers are configured in `config.yaml` and managed at runtime by `MCP.Manager`. Tools are discovered dynamically and merged with native tools in the Executor's function calling interface — the LLM sees one unified tool list regardless of origin.

Supported transports: **stdio**, **HTTP**.

```yaml
# config.yaml
mcp:
  servers:
    github:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-github"]
```

## Mix Tasks

| Command | Purpose |
|---|---|
| `mix pincer.chat` | Interactive CLI agent |
| `mix pincer.server` | Start persistent node (all enabled channels) |
| `mix pincer.onboard` | Bootstrap config and scaffold agent workspaces |
| `mix pincer.agent new <id>` | Create a new agent workspace |
| `mix pincer.agent pair <id>` | Generate a Telegram pairing code |
| `mix pincer.doctor [--strict]` | Operational diagnostics |
| `mix pincer.security_audit [--strict]` | Security-focused audit |
| `mix pincer.memory.report` | Memory system report |
| `mix pincer.memory.explain` | Explain memory state |
| `mix pincer.full_sync` | Full graph synchronization |
| `mix pincer.purge_indices` | Purge search indices |

## Development

### QA Gate

```bash
mix qa
```

Runs `format --check-formatted`, `compile --warnings-as-errors`, and `test --warnings-as-errors --max-failures 1`. All three must pass.

### Running Tests

```bash
docker compose up -d postgres     # database required
mix test                          # all tests
mix test.quick                    # stale tests only
mix test test/pincer/core/executor_test.exs   # single file
```

### Development Protocol

All development follows **Doc-First + TDD**:

1. **Spec first** — document the interface before writing code
2. **Red -> Green -> Refactor** — write a failing test, implement minimum code, then improve
3. No `.ex` without a corresponding `.exs` test file
4. Acceptance requires `@moduledoc`/`@doc`, happy-path + error-path tests, and `mix format` passing

### Boundary Enforcement

The `boundary` compiler plugin enforces dependency direction at compile time:

- `Adapters` may depend on `Core`, `Ports`, `Infra`, `Utils`
- `Core` may only depend on `Ports`, `Infra`, `Utils`
- `Ports` may only depend on `Infra`
- Violations surface as compiler warnings; `mix compile --warnings-as-errors` fails on them

## Stats

- 214 source modules, 163 test files
- 14 LLM provider adapters, 6 channel adapters, 21 tool modules
- ~80 tool actions available to agents

## License

[MIT](LICENSE)
