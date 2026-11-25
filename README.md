# Pincer

Autonomous AI agents on the BEAM — OTP supervision, multi-channel messaging, MCP tool integration, and provider-agnostic LLM access with automatic failover.

**What it does**: Pincer is an Elixir/OTP framework that runs persistent AI agents. Each agent gets a supervised GenServer session, can use 80+ tool actions across 18 native tool modules, talks to humans through Telegram/Discord/CLI/webhook, and remembers conversations across restarts using a tiered memory system backed by embedded SQLite3 (FTS5, with optional sqlite-vec semantic search).

**Who it's for**: Developers building long-running AI assistants that need fault tolerance, multi-channel presence, and structured memory — without babysitting.

**Who it's not for**: If you need a stateless chatbot wrapper, a single-function-call orchestrator, or something that runs in a Lambda, Pincer is more infrastructure than you need.

---

## Quickstart

### Docker (recommended)

```bash
git clone https://github.com/manelsen/Pincer.git && cd Pincer
cp .env.example .env
# Set at least one LLM API key in .env (e.g., GROQ_API_KEY)
docker compose up --build -d
docker compose exec pincer-server mix pincer.chat
```

The image builds `sqlite-vec` (optional vector search) and boots the single-container supervision tree. No external database service is started or required.

### Local (Elixir)

No Docker or external database required — storage is embedded SQLite3 + FTS5 + WAL (`exqlite`):

```bash
git clone https://github.com/manelsen/Pincer.git && cd Pincer
mix deps.get
mix pincer.setup --yes   # deps → SQLite onboard → initializes data/pincer.db
mix pincer.chat
```

`mix pincer.setup` guides you through the full first-run sequence interactively. Use `--yes` for a non-interactive run with defaults and `--sqlite-path <path>` to customize the SQLite file location. `storage.adapter` accepts only `"sqlite"`; PostgreSQL is rejected at boot.

### Reconfigure / Diagnose

```bash
mix pincer.onboard              # re-run configuration wizard
mix pincer.doctor               # health check: config, storage, tokens, LLM, sqlite-vec
mix pincer.doctor --strict      # same, but fail on warnings
```

## Requirements

| Dependency | Minimum Version | Why |
|---|---|---|
| Elixir | 1.20.5+ | Compilation target |
| Erlang/OTP | 27+ | `boundary` compiler plugin |
| SQLite3 (embedded via `exqlite`) | Built-in (FTS5) | Message, graph, and FTS5 storage (no external server) |
| C toolchain (`git`, `make`, `cc`) | *(optional)* | Builds `sqlite-vec` via `./scripts/build_sqlite_vec.sh` for native vector search; search falls back to in-process cosine similarity when absent |
| Node.js | 18+ *(optional)* | MCP sidecar servers |
| Docker / Podman | *(optional)* | Hardened container sandbox backend (`sandbox.adapter: "docker"`) |

### Bubblewrap sandbox (Linux, opt-in)

`sandbox.local.transport: "bwrap"` needs the `bwrap` binary and `prlimit`
(util-linux), plus permission to create unprivileged user namespaces. On Ubuntu
24.04+ where `kernel.apparmor_restrict_unprivileged_userns=1`, install and
enforce the `bwrap-userns-restrict` AppArmor profile shipped under
`infrastructure/apparmor/`. The boot probe fails closed if bwrap or prlimit is
unavailable; `PINCER_SANDBOX_TRANSPORT=os` overrides the YAML transport. The
Docker image ships `bubblewrap`, but the default container security profile
blocks nested user namespaces, so `docker-compose.yml` pins the container to the
OS transport. Use bwrap for bare-metal runs.

See [docs/operations/bubblewrap-sandbox.md](docs/operations/bubblewrap-sandbox.md)
for the installation, verification, and troubleshooting steps.

## Configuration

Runtime config lives in `config.yaml`, not `config/*.exs`. The `Pincer.Infra.Config` module loads it at startup. Edit `config.yaml` to configure:

- **LLM providers** — set `llm.provider` and add API keys to `.env`
- **Channels** — enable/disable Telegram, Discord, CLI, webhook, WhatsApp, LINE, DingTalk, Feishu/Lark
- **MCP servers** — add external tool servers under `mcp.servers`
- **Storage** — embedded SQLite only: `storage.adapter: "sqlite"`, `storage.path: "data/pincer.db"`, and optional `storage.vec` / `vec_path` / `vec_dimensions` (see [Storage](#storage-sqlite))
- **Sandbox execution** — set `sandbox.adapter` (`"local"`, `"docker"`, `"ssh"`) or override with `PINCER_SANDBOX_ADAPTER`
- **Workspace isolation** — `tools.restrict_to_workspace: true` (default) confines file/shell tools to the agent's workspace

### Storage (SQLite)

SQLite is the only storage backend. It runs in-process (`Pincer.Infra.SQLite`), needs no database service, and boot rejects `postgres`/`postgresql` adapters.

```yaml
# config.yaml
storage:
  adapter: "sqlite"                    # only "sqlite" is accepted
  path: "data/pincer.db"
  vec: "auto"                          # auto | true | false
  vec_path: "priv/sqlite_vec/vec0.so"  # optional explicit extension path
  # vec_dimensions: 1024               # embedding width (default 1024)
```

Environment overrides:

| Variable | Effect |
|---|---|
| `PINCER_SQLITE_PATH` | Database file (default `data/pincer.db`; `:memory:` for ephemeral) |
| `PINCER_STORAGE` | Backend selector; must be `sqlite`/`sqlite3` |
| `PINCER_SQLITE_VEC` | `auto`, `true`, `false`, `1`, `0` — enable sqlite-vec |
| `PINCER_SQLITE_VEC_PATH` | Path to `vec0.so` |
| `PINCER_SQLITE_VEC_DIMENSIONS` | Embedding dimensions (default 1024) |

**Vector search:** semantic recall uses [sqlite-vec](https://github.com/asg017/sqlite-vec) when available. Build the extension once with:

```bash
./scripts/build_sqlite_vec.sh          # clones v0.1.10-alpha.4 and writes priv/sqlite_vec/vec0.so
```

The Docker image does this at build time. With `storage.vec: "auto"` or `"true"`, the loader tries `vec_path` and falls back gracefully. Set `PINCER_SQLITE_VEC=0` to disable it explicitly; search then uses in-process cosine similarity over stored vectors. FTS5 full-text search is always available.

### DingTalk

```yaml
# config.yaml
channels:
  dingtalk:
    enabled: true
    adapter: "Pincer.Channels.DingTalk"
    client_id_env: "DINGTALK_CLIENT_ID"
    client_secret_env: "DINGTALK_CLIENT_SECRET"
```

Set `DINGTALK_CLIENT_ID` and `DINGTALK_CLIENT_SECRET` in `.env`.
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

### Feishu / Lark

```yaml
# config.yaml
channels:
  feishu:
    enabled: true
    adapter: "Pincer.Channels.Feishu"
    # Feishu (China): https://open.feishu.cn
    # Lark (International): https://open.larksuite.com
    base_url: "https://open.feishu.cn"
    app_id_env: "FEISHU_APP_ID"
    app_secret_env: "FEISHU_APP_SECRET"
```

Set `FEISHU_APP_ID` and `FEISHU_APP_SECRET` in `.env`.

## Architecture

Pincer uses **Hexagonal Architecture** (Ports & Adapters) with compile-time boundary enforcement. Dependencies flow inward — outer layers can depend on inner, never the reverse:

```
Channels       Telegram, Discord, Slack, WhatsApp, LINE, Feishu/Lark, DingTalk, CLI, Webhook
    ↓
Adapters       Concrete implementations: MCP, Cron, Tools, Sandbox (Local, Docker, SSH)
    ↓
Core           Domain logic: Executor, Session, Orchestration, Memory, Introspection, Skills
    ↓
Ports          Behaviour contracts (LLM, Storage, Channel, Tool, Sandbox)
    ↓
Infra          PubSub, Config, Embedded SQLite3 (FTS5 + optional sqlite-vec)
```

The `boundary` compiler plugin enforces this at compile time. `mix compile --warnings-as-errors` will fail if an inner layer reaches outward.

### Sandbox Execution (`Pincer.Ports.Sandbox`)

Validated shell commands (`Pincer.Adapters.Tools.SafeShell` + `WorkspaceGuard`) run through `Pincer.Ports.Sandbox` with three pluggable adapters:

- **`Pincer.Adapters.Sandbox.Local`** (default): workspace-confined execution (MCP `"run_command"` delegation or bounded local runner)
- **`Pincer.Adapters.Sandbox.Docker`**: ephemeral containers with `--cap-drop ALL`, `--security-opt no-new-privileges`, `--network none` by default, bounded PIDs/RAM/CPU, `--tmpfs` mounts for `/tmp` and `/var/tmp`, and confined `/workspace` bind mounts (auto-detects `docker` or `podman`)
- **`Pincer.Adapters.Sandbox.SSH`**: hardened remote execution (`BatchMode=yes`, strict host-key checking, flag-injection validation, optional ControlMaster multiplexing)

### Closed-Loop Introspection & Skill Promotion

Recurring high-confidence lessons tracked by `Pincer.Core.Introspection.Kernel` and `LessonStore` are synthesized into reusable `SKILL.md` artifacts by `Pincer.Core.Skills.Generator`, scanned by `Pincer.Core.Skills.Guard` under a **fail-closed** security policy (anti-exfiltration, destructive payload, persistence, prompt-injection, and invisible Unicode checks), indexed via `Pincer.Core.Skills.PromptIndex`, and hot-injected into active `Session.Server` prompts on `{:kernel_skills_updated, skill}`.

### Supervision Tree

Every component is supervised. If the LLM client crashes, it restarts. If a user session dies, it restarts — without losing the rest of the tree.

```
Pincer.Supervisor (one_for_one)
├── Infra.PubSub
├── Finch                       HTTP connection pool
├── Infra.SQLite                Embedded SQLite3 (raw connection)
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
| **Semantic** | SQLite3 + FTS5 (optional sqlite-vec) | Structured knowledge graph: bugs, decisions, patterns, people, entities |

Before each LLM call, `MemoryRecall` searches all three layers and injects relevant context into the prompt. Memory content is sanitized to prevent prompt injection.

The **Archivist** runs after each session turn and extracts structured knowledge — bug fixes, architectural decisions, code patterns, people, animals, and entity relationships — storing them as typed nodes and edges in the graph.

## Channels

Each channel implements the `PincerPorts.Channel` behaviour and uses the injected `__using__` macro for PubSub-driven session callbacks. To add a new channel, implement the behaviour and override the callbacks you need (`on_agent_response`, `on_agent_partial`, `on_agent_error`, etc.) — the rest default to no-ops.

| Channel | Module | Notes |
|---|---|---|
| CLI | `Pincer.Channels.CLI` | Enabled by default in config |
| Telegram | `Pincer.Channels.Telegram` | Requires `TELEGRAM_BOT_TOKEN` |
| Discord | `Pincer.Channels.Discord` | Requires `DISCORD_BOT_TOKEN` |
| Slack | `Pincer.Channels.Slack` | Requires Slack app credentials |
| WhatsApp | `Pincer.Channels.WhatsApp` | Requires Go bridge binary |
| LINE | `Pincer.Channels.Line` | Requires `LINE_CHANNEL_ACCESS_TOKEN` + `LINE_CHANNEL_SECRET` |
| DingTalk | `Pincer.Channels.DingTalk` | Requires `DINGTALK_CLIENT_ID` + `DINGTALK_CLIENT_SECRET` |
| Feishu / Lark | `Pincer.Channels.Feishu` | Requires `FEISHU_APP_ID` + `FEISHU_APP_SECRET`. Set `base_url` for Lark (international) |
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

14 providers, all implementing the `PincerPorts.LLM.Provider` behaviour. The `LLM.Client` dispatches to the configured adapter and handles retry/failover transparently.

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

18 registered native tool modules with ~80 tool actions, all implementing the `Pincer.Ports.Tool` behaviour (`spec/0` + `execute/1` or `execute/2`). MCP-discovered tools merge into the same surface at runtime.

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
| `mix pincer.setup` | First-run bootstrap (deps, SQLite init, onboard; `--yes`, `--sqlite-path`) |
| `mix pincer.onboard` | Bootstrap config and agent workspaces (`--sqlite-path`) |
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
mix test                          # all tests (excludes opt-in :docker, :bwrap, :chaos, :stress)
mix test.quick                    # stale tests only
mix test --only docker            # opt-in real Docker container sandbox E2E
mix test test/pincer/core/executor_test.exs   # single file
```

The full suite runs on embedded SQLite with `PINCER_SQLITE_PATH=:memory:` (set in `config/test.exs`); no database service, Compose stack, or migration step is needed. `sqlite-vec` is optional for tests — when the extension is absent, storage tests use the cosine-similarity fallback.

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

- 247 root Elixir source files (`lib/`) + 72 package source files across 25 subpackages (`packages/`)
- 250 test files (`*_test.exs`)
- 14 LLM provider adapters, 9 channel packages, 18 native tool modules
- ~80 tool actions available to agents

## Governance & Security

- Security policy & private vulnerability reporting: [SECURITY.md](SECURITY.md)
- Contributing guide: [CONTRIBUTING.md](CONTRIBUTING.md)
- Release history: [CHANGELOG.md](CHANGELOG.md)
- Code of conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## License

[MIT](LICENSE)
