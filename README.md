# Pincer

Autonomous AI agent framework built on the BEAM. OTP supervision, multi-channel messaging, MCP integration, sub-agents via Blackboard pattern, and provider-agnostic LLM access with failover.

## Architecture

Pincer uses a **Hexagonal Architecture** (Ports & Adapters) with boundary enforcement via the `boundary` compiler plugin. Dependencies flow inward:

```
Pincer.Infra       PubSub, Config, Ecto Repo
      ↑
Pincer.Ports       Behaviour contracts (LLM, Storage, Channel, Tool, Cron...)
      ↑
Pincer.Core        Domain logic: Executor, Session, Orchestration, Memory, LLM failover
      ↑
Pincer.Adapters    Concrete implementations: MCP, Cron, Tools, Channel adapters
      ↑
Pincer.Channels    Telegram, Discord, Slack, WhatsApp, CLI, Webhook
```

### Supervision Tree

```
Pincer.Supervisor (one_for_one)
├── Pincer.Infra.PubSub
├── Pincer.Finch                    HTTP connection pool
├── Pincer.Infra.Repo               Ecto/PostgreSQL
├── Pincer.Core.Heartbeat           Health checks + GitHub watcher
├── Pincer.Dispatcher.Registry      Message dispatcher (duplicate keys)
├── Pincer.MCP.Supervisor           DynamicSupervisor for MCP servers
├── MCP.Manager                     MCP lifecycle + tool discovery
├── Session.Registry                Active sessions (unique keys)
├── HookDispatcher                  Lifecycle hooks
├── Session.Supervisor              DynamicSupervisor for user sessions
├── Project.Registry / Supervisor   Multi-project isolation
├── Cron.Scheduler                  Persistent scheduled jobs
├── Channels.Supervisor             Channel adapters
├── Telegram/Discord/WhatsApp       SessionSupervisors per channel
└── Reloader (dev only)             Hot code reloading
```

## Key Subsystems

| Subsystem | Location | Purpose |
|---|---|---|
| **Executor** | `lib/pincer/core/executor.ex` | Agentic reasoning loop; resolves tools and LLM, max 25 recursion depth |
| **Session** | `lib/pincer/core/session/` | `GenServer` per user session; supervised by `Session.Supervisor` |
| **Blackboard** | `lib/pincer/core/orchestration/blackboard.ex` | Tiered ETS (hot) + disk journal (cold) event store for inter-agent communication |
| **SubAgent** | `lib/pincer/core/orchestration/sub_agent.ex` | Spawns child agents; progress tracked via `SubAgentProgress` |
| **MCP Manager** | `lib/pincer/adapters/connectors/mcp/manager.ex` | Lifecycle + tool discovery for MCP servers |
| **LLM Client** | `lib/pincer/llm/client.ex` | Provider-agnostic LLM calls with failover (`FailoverPolicy`) |
| **Graph Memory** | `lib/pincer/storage/graph/` | Relational memory stored as nodes/edges in PostgreSQL with pgvector |
| **Cron Scheduler** | `lib/pincer/adapters/cron/scheduler.ex` | Persistent cron jobs via Ecto-backed storage |
| **Memory** | `lib/pincer/core/memory.ex` | Two-layer memory: rolling `HISTORY.md` + curated `MEMORY.md` with consolidation |
| **Archivist** | `lib/pincer/core/orchestration/archivist.ex` | Memory consolidation, snippet indexing, user preference extraction |

## LLM Providers

Each provider implements the `Pincer.LLM.Provider` behaviour. The `LLM.Client` dispatches to the configured adapter and handles retry/failover transparently.

| Provider | Module | Notes |
|---|---|---|
| OpenAI-compatible | `Providers.OpenAICompat` | Base for most providers |
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

## Channels

Each channel implements the `Pincer.Ports.Channel` behaviour and uses the injected `__using__` macro for PubSub-driven session callbacks (`on_agent_response`, `on_agent_partial`, `on_agent_error`, etc.).

| Channel | Module | Status |
|---|---|---|
| CLI | `Pincer.Channels.CLI` | Active |
| Telegram | `Pincer.Channels.Telegram` | Active |
| Discord | `Pincer.Channels.Discord` | Available |
| Slack | `Pincer.Channels.Slack` | Available |
| WhatsApp | `Pincer.Channels.WhatsApp` | Available (Go bridge) |
| Webhook | `Pincer.Channels.Webhook` | Available |

## Built-in Tools

21 tool modules (~80 actions), all implementing the `Pincer.Ports.Tool` behaviour (`spec/0` + `execute/1` or `execute/2`).

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

MCP (Model Context Protocol) servers are configured in `config.yaml` and managed at runtime by `MCP.Manager`. Tools are discovered dynamically and merged with native tools in the Executor's function calling interface.

Supported transports: **stdio**, **HTTP**.

## Memory System

- **Short-term**: `workspaces/<agent_id>/.pincer/HISTORY.md` -- rolling session log
- **Long-term**: `workspaces/<agent_id>/.pincer/MEMORY.md` -- curated insights with consolidation
- **Semantic**: PostgreSQL nodes/edges with pgvector embeddings
- **Recall**: `MemoryRecall` module performs automatic context injection before each LLM call
- **Sanitization**: Memory content is sanitized before prompt injection to prevent prompt injection attacks

## Requirements

- Elixir 1.18+ / Erlang 27+
- PostgreSQL 18+ with pgvector extension
- Node.js (for MCP sidecar servers)

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/micelio/pincer.git
cd pincer
cp .env.example .env
# Edit .env with your API keys
```

### 2. Start with Docker Compose

```bash
docker compose up --build -d
```

This starts PostgreSQL (pgvector) and the Pincer server.

### 3. Or run locally

```bash
# Start PostgreSQL
docker compose up -d postgres

# Setup database
mix deps.get
mix ecto.create && mix ecto.migrate

# Start the server
mix pincer.server

# Or use the interactive CLI
mix pincer.chat
```

### Configuration

Runtime config is loaded from `config.yaml` (not `config/*.exs`) by `Pincer.Infra.Config` at startup. Edit `config.yaml` to configure channels, LLM providers, MCP servers, and database connections.

## Mix Tasks

| Command | Purpose |
|---|---|
| `mix pincer.chat` | Interactive CLI agent |
| `mix pincer.server` | Start persistent node (all enabled channels) |
| `mix pincer.onboard` | Bootstrap config and scaffold agent workspaces |
| `mix pincer.agent new <id>` | Create a new agent |
| `mix pincer.agent pair <id>` | Pair an agent with a channel |
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

Runs `format --check-formatted`, `compile --warnings-as-errors`, and `test --warnings-as-errors --max-failures 1`.

### Quick Test

```bash
mix test.quick              # Stale tests only
mix test                    # All tests
mix test test/pincer/core/executor_test.exs  # Single file
```

### Development Protocol

All development follows **Doc-First + TDD**:

1. **Spec first**: Document the interface in `SPECS.md` or the task plan before writing code.
2. **Red -> Green -> Refactor**: Write a failing test, implement minimal code, then improve.
3. No `.ex` without a corresponding `.exs` test file.
4. Acceptance requires `@moduledoc`/`@doc`, happy-path + error-path tests, and `mix format` passing.

### Boundary Enforcement

The `boundary` compiler plugin enforces dependency direction at compile time:

- `Pincer.Adapters` may depend on `Pincer.Core`, `Pincer.Ports`, `Pincer.Infra`, `Pincer.Utils`.
- `Pincer.Core` may only depend on `Pincer.Ports`, `Pincer.Infra`, `Pincer.Utils`.
- `Pincer.Ports` may only depend on `Pincer.Infra`.
- Violations surface as compiler warnings; `mix compile --warnings-as-errors` will fail on them.

## Project Stats

- **214** source modules (`lib/`)
- **150** test files (`test/`)
- **17** LLM provider adapters
- **6** channel adapters
- **21** built-in tool modules

## License

MIT License. See [LICENSE](LICENSE).
