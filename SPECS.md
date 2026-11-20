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

---

### 14. Sandbox Execution Port (`Pincer.Ports.Sandbox`)

Hexagonal execution boundary decoupling shell safety policy (`Pincer.Adapters.Tools.SafeShell`
and `Pincer.Core.WorkspaceGuard`) from where and how validated commands run.

- **Contract (`Pincer.Ports.Sandbox`)**:
  - `backend_name/0 :: atom()`
  - `available?/0 :: boolean()`
  - `run/2 :: (command, opts) -> {:ok, %{output, exit_code, backend, metadata}} | {:error, term()}`
  - `cleanup/1 :: (scope_id) -> :ok | {:error, term()}`
- **Environment Security (`Sandbox.validate_env/1`)**:
  Rejects unsafe loader/shell injection variables (`LD_PRELOAD`, `LD_LIBRARY_PATH`,
  `DYLD_*`, `BASH_ENV`, `ENV`, `IFS`), malformed names, and non-binary entries before
  dispatching to any backend.
- **Pluggable Adapters (`lib/pincer/adapters/sandbox/`)**:
  1. **`Local`** (default): preserves MCP `ToolRegistry` `"run_command"` delegation by
     default and supports an opt-in `:os` runner transport (`sh -c` with timeout enforcement
     and `WorkspaceGuard.confine_path/2` path confinement).
  2. **`Docker`**: ephemeral hardened container runner (`--rm`, `--cap-drop ALL`,
     `--security-opt no-new-privileges`, `--pids-limit`, `--memory`, `--cpus`, bounded
     `/tmp` and `/var/tmp` `--tmpfs` mounts, `--network none` default, confined workspace
     bind mount, sanitized `pincer-scope` labels, Docker/Podman auto-detection).
  3. **`SSH`**: hardened remote execution (`BatchMode=yes`, strict host-key checking,
     option-injection guards rejecting leading `-` hosts/users and invalid ports,
     ControlMaster multiplexing support, POSIX shell quoting).
- **Configuration (`config.yaml` / env)**:
  - `sandbox.adapter`: `"local" | "docker" | "ssh"` (or module name)
  - `PINCER_SANDBOX_ADAPTER` overrides `config.yaml` at boot.

```elixir
{:ok, %{output: out, exit_code: 0, backend: :local}} =
  Pincer.Ports.Sandbox.run("git status", workspace_path: "/path/to/workspace")
```

### 15. Closed-Loop Introspection → Skill Generation (`Core.Skills.*` + `Introspection.Kernel`)

Closes the self-improvement loop so recurring validated lessons in `Introspection.LessonStore`
are promoted into reusable workspace `SKILL.md` artifacts and dynamically injected back into
active agent prompts.

- **Security Gate (`Pincer.Core.Skills.Guard`)**:
  - Validates skill slug format (`^[a-z0-9][a-z0-9_-]{0,63}$`), YAML frontmatter,
    description length budget (`<= 512` chars), and body size budget (`<= 16_384` chars).
  - Runs static security scanning across five threat categories (`exfiltration`,
    `destructive`, `persistence`, `injection`, and invisible Unicode/bidi control chars)
    with loopback URL exemption (`localhost` / `127.0.0.1` / `[::1]`).
  - Enforces a **fail-closed** policy for agent-generated skills (`verdict == :dangerous`
    blocks installation and leaves disk + lesson metadata untouched).
- **Promotion Engine (`Pincer.Core.Skills.Generator`)**:
  - Selects eligible lessons (`active == true`, `confidence >= 0.75`, `success_count >= 2`,
    and `meta["promoted_skill"] == nil`).
  - Synthesizes structured `SKILL.md` via `Introspection.Client` (or deterministic fallback
    when configured), validates with `Skills.Guard.validate_and_scan/2`, confines target
    path inside `workspaces/<agent>/.pincer/skills/<slug>/SKILL.md` via `WorkspaceGuard`,
    writes atomically via temp file + `File.rename`, bumps patch semver when updating an
    existing skill, and records `LessonStore.mark_promoted/2`.
- **Kernel & Prompt Feedback Loop**:
  - `Pincer.Core.Introspection.Kernel` exposes `promote_skills/1` and asynchronously checks
    for promotable lessons after reflection cycles (throttled via
    `:skill_promotion_throttle_ms`, configurable via `:enable_skill_promotion`).
  - On promotion, Kernel broadcasts `{:kernel_skills_updated, skill}` to registered
    `Session.Server` processes, which rebuild the system prompt header immediately using
    `Pincer.Core.Skills.PromptIndex.build/2` (`Loader.discover/1` + requirements filtering).

### 16. Optional Zero-Infra SQLite Storage (`Pincer.Infra.SQLite` + `Pincer.Storage.Adapters.SQLite`)

Allows booting and running Pincer with zero external database infrastructure using embedded
`exqlite` SQLite3 + FTS5 + WAL mode, while keeping PostgreSQL + pgvector as the default.

- **Engine (`Pincer.Infra.SQLite`)**:
  - GenServer owning an `Exqlite.Sqlite3` connection with `PRAGMA foreign_keys = ON`,
    `PRAGMA busy_timeout = 5000`, and on file-backed DBs `PRAGMA journal_mode = WAL` +
    `PRAGMA synchronous = NORMAL`.
  - Runs idempotent DDL initialization on open across core storage tables (`messages`,
    `messages_fts`, `nodes`, `edges`, `documents_fts`, `checkpoints`, `pairing_states`)
    and subsystem tables (`self_states`, `lessons`, `cron_jobs`, `audit_log`,
    `dead_letter_queue`).
- **Storage Adapter (`Pincer.Storage.Adapters.SQLite`)**:
  - Implements every callback of `Pincer.Ports.Storage` with Postgres-compatible map/struct
    contracts, FTS5 full-text search (with safe query quoting and substring fallback), and
    pure-Elixir cosine similarity over stored float vectors for `search_similar/3`.
- **Zero-Infra Boot & Secondary Persistence**:
  - Enabled via `database.adapter: "sqlite"` or `storage.adapter: "sqlite"` in `config.yaml`,
    or `PINCER_STORAGE=sqlite` (`PINCER_SQLITE_PATH` defaults to `"data/pincer.db"`).
  - `Pincer.Core.StartupGuard` verifies SQLite parent-dir/file writability and skips
    PostgreSQL TCP & Ecto migration checks when SQLite mode is active.
  - `Pincer.Application` starts `Pincer.Infra.SQLite` instead of `Pincer.Infra.Repo`.
  - `SelfState`, `LessonStore`, `Cron.Storage`, `AuditLog`, `DeadLetterQueue`, and
    `CircuitBreaker` route cleanly to `Pincer.Infra.SQLite` (or ETS-only for circuit
    snapshots) when SQLite mode is active.

### 17. Inspiration & Attribution (`~/git/hermes-agent`)

Several security, self-improvement, and embedded-persistence designs in §§14–16 were
inspired by patterns in Nous Research's Hermes Agent (`~/git/hermes-agent`) and adapted
idiomatically to Elixir/OTP and Pincer's Hexagonal Boundaries:

1. **Isolated Execution & Conformance (`~/git/hermes-agent/tools/environments/{base,docker,ssh,sandbox_conformance}.py`)** → Inspired `Pincer.Ports.Sandbox`, hardened `Docker` container flags (`--cap-drop ALL`, `no-new-privileges`, bounded `/tmp` & `/var/tmp` tmpfs mounts, default `--network none`, Docker/Podman detection, sanitized tracking labels), hardened `SSH` validation/ControlMaster patterns, and the shared `Pincer.Test.Support.SandboxConformance` contract suite.
2. **Skill Validation & Threat Guard (`~/git/hermes-agent/tools/{skills_guard,skill_manager_tool}.py`)** → Inspired `Pincer.Core.Skills.Guard` threat categories (`exfiltration`, `destructive`, `persistence`, `injection`, invisible Unicode chars) with loopback exemptions and descriptive-prose safeguards, slug/size budgets, atomic temp-file writes, and fail-closed gating for agent-authored skills generated by `Pincer.Core.Skills.Generator`.
3. **Zero-Infra SQLite & FTS5 Persistence (`~/git/hermes-agent/persistence/sqlite/{_schema_ddl,_backend}.py`)** → Inspired `Pincer.Infra.SQLite` WAL/busy-timeout pragmas, idempotent startup DDL, FTS5 virtual tables kept synchronized via triggers/mutations, and safe FTS5 query tokenization/quoting in `Pincer.Storage.Adapters.SQLite`.

### 18. Multi-Backend Index Purge & Config Atom Allowlist

Follow-up hardening consolidating post-merge behavior across PostgreSQL and SQLite:

- **`Pincer.Ports.Storage.purge_invalid_documents/1`**:
  - Contract: `purge_invalid_documents(prefixes :: [String.t()]) :: {:ok, non_neg_integer()} | {:error, term()}` (default prefixes `["tmp/", "workspaces/"]`).
  - `Pincer.Storage.Adapters.Postgres` deletes `document` nodes matching JSONB `data->>'path' LIKE ... ESCAPE '!'`.
  - `Pincer.Storage.Adapters.SQLite` executes atomically inside `Pincer.Infra.SQLite.transaction/2`, removing matching `document` rows in `nodes` (`json_extract(data, '$.path') LIKE ... ESCAPE '!'`) **and** corresponding entries in `documents_fts` so no orphan FTS5 records remain.
  - `Mix.Tasks.Pincer.PurgeIndices` delegates to `Pincer.Ports.Storage` rather than coupling directly to `Pincer.Infra.Repo`.
- **`Pincer.Infra.Config` Atom Allowlists**:
  - `load/1` maps YAML top-level keys only through an explicit `@allowed_top_level_keys` table; unknown keys log a warning and are ignored without calling `String.to_atom/1`.
  - `configure_database/1` maps Ecto/Postgrex `database` options only through `@allowed_ecto_keys`; unknown keys log a warning and are ignored without calling `String.to_atom/1`.

### 19. Zero-Infra SQLite Onboarding & Diagnostics

Extends `setup`, `onboard`, `doctor`, and user documentation so Pincer can be bootstrapped
and validated with zero external PostgreSQL/Docker dependencies:

- **`Pincer.Infra.SQLite.health_check/0`**:
  - Opens an in-memory SQLite3 connection (`:memory:`), creates and drops a temporary
    `fts5` virtual table, and closes the connection cleanly, returning `:ok` or
    `{:error, reason}`.
- **Storage Mode Resolution (`mix pincer.setup` & `mix pincer.onboard`)**:
  - Flags: `--storage <sqlite|postgres>`, `--sqlite-path <path>` (default `"data/pincer.db"`),
    and `--config <path>` (default `"config.yaml"`).
  - Precedence when `--storage` is omitted: `PINCER_STORAGE` env var > configured
    `storage.adapter` / `database.adapter` in `--config` / `config.yaml` > `:postgres` default.
  - Under `:sqlite`, `mix pincer.setup` skips PostgreSQL TCP wait / `ecto.create` /
    `ecto.migrate`, forwards `--storage`, `--sqlite-path`, and `--config` to
    `mix pincer.onboard`, and runs idempotent SQLite schema initialization.
  - `Pincer.Core.Onboard.Defaults.defaults/1` emits `storage: {adapter: "sqlite", path: ...}`
    and `sandbox: {adapter: "local"}` for `:sqlite` without requiring a `database` block.
  - `Pincer.Core.Onboard.Preflight` validates `storage.path` writability (rejecting empty
    strings, `..` traversal segments, and non-directory/file parents) and uses
    `SQLite.health_check/0` in `check_db_connectivity/1`.
- **Diagnostics (`Pincer.Core.Doctor`)**:
  - Adds `storage_checks` emitting `:storage_backend` (`:ok`), `:sqlite_path` (`:ok` / `:error`),
    and `:sqlite_engine` (`:ok` / `:error`) in SQLite mode with zero PostgreSQL false positives,
    plus basic `database` shape validation in Postgres mode without blocking network calls.



