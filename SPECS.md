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

### Storage overrides

Storage is embedded SQLite only. Optional env vars override `config.yaml`:

```
PINCER_STORAGE                  # must be sqlite/sqlite3
PINCER_SQLITE_PATH              # database file, default data/pincer.db; :memory: is ephemeral
PINCER_SQLITE_VEC               # auto (default) | true | false
PINCER_SQLITE_VEC_PATH          # path to vec0.so, default priv/sqlite_vec/vec0.so
PINCER_SQLITE_VEC_DIMENSIONS    # embedding width, default 1024
```

`sqlite-vec` is optional: `./scripts/build_sqlite_vec.sh` builds the pinned extension
(`v0.1.10-alpha.4` by default) into `priv/sqlite_vec/vec0.so`. With `vec: "auto"`/`"true"`
the loader attempts to load it; otherwise `search_similar/3` uses in-process cosine
similarity. FTS5 full-text search is always available.

---

## Subsystems

### 1. Session Pruner (`Pincer.Core.Executor.Pruner`)

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

#### Skills registry adapters

`PincerPorts.SkillsRegistry` defines `list_skills/1` and `fetch_skill/2` for
catalog adapters. Discovery and installation use the configured `:local`
adapter by default. Callers can select `:clawhub` or supply an adapter module
through `:registry`. Modules supplied per call take precedence and receive
`:registry_opts` unchanged. Pincer configures the named adapters in
`:skills_registry_adapters`. The `:skills_registry` setting remains the local
catalog.

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
- Both default and fallback models are 1024-dimensional, matching
  `storage.vec_dimensions` (default 1024) and the cosine-similarity fallback.

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

- `Pincer.Core.Executor.PromptAssembly` builds the base system prompt (`build_system_prompt/1`,
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

### 12. Boundary Normalization (`Pincer.Infra.Config`, `PincerPorts.Structs.Usage`)

External payloads are normalized once at ingestion boundaries:

- `Pincer.Infra.Config.load_file/1` and `normalize_keys/1` convert YAML and merged
  configuration keys to canonical `snake_case` strings at load time (preserving
  structs and uppercase env-var keys), eliminating camelCase/snake_case dual lookups.
- `PincerPorts.Structs.Usage` defines `%Usage{prompt_tokens, completion_tokens, total_tokens}`
  normalized once at `Pincer.LLM.Client`, `Executor`, and `Session.Preferences` boundaries.
- `model_override` is normalized to atom-keyed maps (`%{provider: ..., model: ...}`).

#### LLM dispatch port

`PincerPorts.LLM` defines the LLM adapter callbacks and dispatches calls through
the host's `:pincer, :llm_adapter` application setting. Channel packages use
the shared port for model and provider discovery and audio transcription.
`Pincer.Ports.LLM` forwards calls during the migration and preserves the
existing callback declarations and default arguments.

### 12.1. Channel PubSub (`PincerPorts.PubSub`)

- Channel packages subscribe with `PincerPorts.PubSub.subscribe/1` and remove subscriptions with `unsubscribe/1`. The `PincerPorts.Channel` macro subscribes channel workers to `system:delivery`.
- The port resolves `:pincer, :pubsub_adapter` at runtime. Pincer's root config installs `Pincer.Infra.PubSub`, which publishes to the existing Registry. A standalone channel host supplies an adapter implementing `subscribe/1`, `unsubscribe/1`, and `broadcast/2`. Missing or invalid adapter configuration raises `ArgumentError`.
- Topic names and mailbox messages are preserved. `broadcast/2` sends its message term to subscribers without wrapping it.

### 12.2. Outbound messaging (`PincerPorts.Messaging`)

- `deliver/2` publishes a session message through the host's existing PubSub.
- `send_message/4`, `send_file/4`, and `reply_to/4` address a channel recipient
  and return the transport's result. Replies carry the message ID as a send
  option. Files have a name, contents, and a path already checked by the caller.
- The host configures one `:messaging_adapter`. Pincer wires the channel adapter
  in application config. Tools resolve destinations and check workspace paths
  before dispatch. The channel adapter selects the transport and its capabilities.

### 12.3. External package boundaries

`Pincer.Adapters`, `Pincer.Core`, `Pincer.Ports`, and `Pincer.LLM` check references
to Pincer's package applications. Calls to an external package boundary require
an explicit dependency on that boundary. Host configuration selects the
concrete channel and provider modules.

### 12.4. Core exports

`Pincer.Core` exports modules used from outside Core by host code or named
as adapters in host configuration. The architecture test uses compiler
references for host code, including supervised children and Mix tasks, and
checks configuration and package sources separately. Registered process names
do not require exports.

`Pincer.Core.UX` owns the interaction payload policy for model selectors,
menus, and approval buttons.

### 12.5. Core sub-boundaries

Session, Project, Orchestration, Introspection, Skills, Executor, Memory, LLM,
and Graph own the code in their namespaces. They declare sibling dependencies
and export the modules those consumers use. The parent re-exports the external
Core contract. Helpers that belong to a slice live under that owner.

A sibling dependency grants access to the target boundary's exports. For
example, Session can call `Executor.PromptAssembly`. A call to the private
`Executor.Ctx` module produces a `not_exported` diagnostic. Compilation with
`--warnings-as-errors` rejects that call.

Session routes project commands through Project. Project reads and resets
sessions through `PincerPorts.Session`. History pruning belongs to Executor's
prompt assembly, so Executor can assemble prompts independently of Session.
Host configuration supplies the skill generator used by Introspection.

### 12.6. Local Git port

`Pincer.Ports.Git` delegates to the host's `:git_adapter`. It exposes project
branch provisioning and two read-only queries for the graph indexer.

- `ensure_branch(name, cwd: workspace)` returns branch status, source branch and
  repository path. In a non-Git workspace it initializes an isolated repository
  under the project's directory.
- `files(workspace, :changed | :tracked)` returns paths relative to the workspace
  or a tagged error. Graph sync skips incremental scans and falls back to a
  filesystem walk for full scans when the workspace has no local Git metadata.

The host application no longer starts the proof-of-concept GitHub poller.

### 12.7. Operational storage ports

The host configures `Pincer.Ports.AuditLog`, `Pincer.Ports.DeadLetterQueue`,
and `Pincer.Ports.IntrospectionStore` separately from the general storage port.
The adapters under `Pincer.Adapters.Storage` own SQL, JSON serialization,
database IDs, and row decoding. The ports exchange atom-keyed records with
decoded values. Core keeps its structs, changeset validation, lesson scoring,
and user-facing result conventions.

- AuditLog inserts validated events and lists recent events, with an optional
  actor or event-type filter.
- DeadLetterQueue inserts validated entries, lists pending work, resolves entries,
  and increments attempts.
- IntrospectionStore reads and writes lesson records and per-agent self-state.
  Lesson reads support active and confidence-ranked queries.

### 12.8. Domain error normalization and Core app boundary

Adapters and infrastructure normalize external client exceptions before returning
errors into Core:

- HTTP, LLM, and attachment boundaries normalize `%Req.TransportError{reason: reason}`
  into `{:transport_error, reason}`.
- `Pincer.Infra.SQLite` normalizes `Exqlite` query, execute, health-check, and
  transaction failures into `{:db_error, reason}` (preserving application-returned
  `{:error, reason}` values and non-SQLite exceptions inside transactions).
- `Pincer.Core.LLM.ErrorClass` and `Pincer.Core.RetryPolicy` classify only domain
  error tuples (`{:transport_error, reason}`, `{:db_error, reason}`) without
  referencing `Req` or `Exqlite`.
- `Pincer.Core` blocks `:req` and `:exqlite` via Boundary `check: [apps: ...]`
  (inherited by Core sub-boundaries).

### 13. Channel-Owned Formatting (`Pincer.Channels.Telegram.ResponseEnvelope`)

Telegram HTML usage-footer formatting and reasoning delivery options reside in
`Pincer.Channels.Telegram.ResponseEnvelope` inside `packages/pincer_telegram`,
keeping `Pincer.Core` transport-agnostic (plain text + structured `%Usage{}`).

### 13.1. Media tool dispatch

The media tool uses `PincerPorts.LLM` directly for image description, OCR, and
audio transcription. Attachment resolution has a separate contract for obtaining
bytes from stored references.

### 13.2. Attachment retrieval

`PincerPorts.Attachments.fetch(reference, mode)` delegates to the host's
`:attachment_adapter` and returns `{:ok, binary}` or `{:error, reason}`.
The Core passes the stored reference unchanged. The host adapter understands
existing Telegram file references and HTTP(S) links. Telegram credentials
stay in the adapter and are resolved at fetch time.
HTTP(S) redirects are validated hop by hop. Telegram downloads use the
configured service endpoint directly.

- `{:inline, max_bytes}` fetches an attachment with a response size limit.
  Executor converts the bytes into provider prompt parts.
- `:workspace` fetches a channel file. Session History writes the bytes under
  the session workspace's `incoming/` directory and records the result.

Channels continue emitting the existing attachment fields, including the
`url` field that holds the opaque reference.

### 13.3. Shared channel session bridge

`Pincer.Channels.Shared.SessionBridge` centralizes per-channel worker
registration (`via_tuple/2-3`), worker/session startup (`ensure_started/2`),
PubSub subscription lifecycle (`subscribe/1`, `unsubscribe/1`, `bind_session/2-3`),
session identifier helpers (`default_session_id/2`, `normalize_session_id/3`,
`handles_session?/2`, `resolve_recipient/2`), and worker state initialization
(`initial_state/2`).

Channel session workers and adapters delegate session lifecycle mechanics to
`SessionBridge` while keeping transport-specific streaming, card updates, and
project-flow delivery callbacks in each channel package.

### 13.4. Shared channel project bridge

`Pincer.Channels.Shared.ProjectBridge` centralizes project wizard continuation
(`continue/3`), execution kickoff orchestration (`kickoff/2`), and session
worker project callbacks (`on_agent_response/2`, `on_agent_error/2`) on top of
`PincerPorts.Project` and `PincerPorts.Session`.

Channel adapters pass transport callbacks (`ensure_session`, `ensure_worker`,
`send_message`, and optional `dispatch`/`on_start_error`/`log_tag`) so Telegram,
Discord, and WhatsApp share identical kickoff and error-recovery sequencing.

### 13.5. Shared channel helpers (Chunking, Formatting, Attachments, Pairing)

- `Pincer.Channels.Shared.Chunking` provides outbound message splitting
  (`split/3` supporting `:lines`, `:newline_window`, and `:graphemes` strategies)
  and incremental stream-buffer flushing (`should_flush_stream?/2`,
  `append_stream_buffer/3`).
- `Pincer.Channels.Shared.Formatting` owns reasoning stripping and HTML formatting
  (`strip_reasoning/1`, `format_reasoning_html/1`, `format_reasoning/2`, preserved
  under `Pincer.Channels.Shared.Text` via delegation), HTML fencing/unfencing and
  Markdown-to-HTML orchestration with an injected renderer callback (`fence_html/2`,
  `unfence_html/2`, `markdown_to_html/2`), file-reference wrapping
  (`wrap_file_references/2`), HTML-to-plain-text fallback (`html_to_plain_text/1`),
  Discord Markdown normalization (`markdown_to_discord/1`), and Slack `mrkdwn`
  conversion (`markdown_to_mrkdwn/1`).
- `Pincer.Channels.Shared.Attachments` centralizes filename sanitization
  (`sanitize_filename/1`), size normalization/validation (`normalize_size/1`,
  `validate_size/2`), extension and MIME classification (`text_extension?/1`,
  `valid_text_content_type?/1`, `multimodal_mime/2`, `multimodal_extension?/3`,
  `resolve_mime/3`), attachment/workspace reference construction (`build_ref/5`),
  metadata formatting (`format_meta/3`, `append_meta/5`, `format_inline_file/2`),
  photo selection (`largest_photo/1`), inbound content and `IncomingMessage`
  assembly (`combine_content/3`, `to_incoming_message/3`), list processing with
  an injected downloader callback (`process_list/2`), and outbound large code-block
  extraction (`extract_large_code_blocks/3`).
- `Pincer.Channels.Shared.Pairing` unifies DM access authorization
  (`authorize_dm/4`), `/pair` command detection and code extraction
  (`pair_command?/1`, `extract_code/1`), and `/pair` code approval (`approve/4`,
  `error_message/1`) on top of `PincerPorts.ChannelPolicy`, supporting
  channel-specific DM-only messages, bound-agent formatting, and post-approval hooks.

### 13.6. Unified channel inbound pipeline (`Pincer.Channels.Shared.Inbound`)

`Pincer.Channels.Shared.Inbound` serves as the standardized inbound entrypoint
for all 7 messaging channels (Telegram, Discord, WhatsApp, DingTalk, LINE,
Feishu, and Slack):

- `route/2` normalizes blank text, allows DM `/pair` commands through, enforces
  `Pincer.Channels.Shared.Pairing.authorize_dm/4` for DMs (returning
  `{:denied, message}` and invoking `:on_denied` on denial), and delegates to
  `dispatch/2` (defaulting `:resolve_shortcut` to
  `PincerPorts.UX.resolve_shortcut/1` and `:continue_project` to
  `Pincer.Channels.Shared.ProjectBridge.continue/3`).
- `handle_standard_command/3` executes common slash commands (`/ping`, `/menu`,
  `/help`, `/commands`, `/new`, `/reset`, `/kanban`, `/project`, `/pair`, and
  unknown command hints) via port callbacks.
- `dispatch_session_message/3` ensures the brain session and channel worker are
  started before delivering `PincerPorts.Structs.IncomingMessage` to
  `PincerPorts.Session.process_input/2`.

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

### 16. Embedded SQLite Storage (`Pincer.Infra.SQLite` + `Pincer.Storage.Adapters.SQLite`)

The only storage backend. Pincer boots and runs with zero external database
infrastructure using embedded `exqlite` SQLite3 + FTS5 + WAL mode.

- **Engine (`Pincer.Infra.SQLite`)**:
  - GenServer owning an `Exqlite.Sqlite3` connection with `PRAGMA foreign_keys = ON`,
    `PRAGMA busy_timeout = 5000`, and on file-backed DBs `PRAGMA journal_mode = WAL` +
    `PRAGMA synchronous = NORMAL`.
  - Runs idempotent DDL initialization on open across core storage tables (`messages`,
    `messages_fts`, `nodes`, `edges`, `documents_fts`, `checkpoints`, `pairing_states`)
    and subsystem tables (`self_states`, `lessons`, `cron_jobs`, `audit_log`,
    `dead_letter_queue`).
- **Storage Adapter (`Pincer.Storage.Adapters.SQLite`)**:
  - Implements every callback of `Pincer.Ports.Storage`, FTS5 full-text search (with safe
    query quoting and substring fallback), and vector search.
  - **Vector search**: when `sqlite-vec` is loaded (`storage.vec: "auto" | true`), vectors
    live in a `vec0` virtual table with native nearest-neighbour search. When the extension
    is unavailable or `storage.vec: false` / `PINCER_SQLITE_VEC=0`, stored float vectors are
    ranked in-process with cosine similarity and identical adapter contracts.
- **Boot & Secondary Persistence**:
  - Enabled via `storage.adapter: "sqlite"` in `config.yaml` (the only valid value);
    `PINCER_STORAGE` can select it explicitly. `PINCER_STORAGE=postgres`/`postgresql`
    raises `ArgumentError` at config load. `PINCER_SQLITE_PATH` defaults to
    `"data/pincer.db"`.
  - `Pincer.Core.StartupGuard` verifies SQLite parent-dir/file writability and sqlite-vec
    loadability when vector search is enabled. There are no migrations.
  - `Pincer.Application` starts `Pincer.Infra.SQLite`.
  - `SelfState`, `LessonStore`, `Cron.Storage`, `AuditLog`, `DeadLetterQueue`, and
    `CircuitBreaker` route cleanly to `Pincer.Infra.SQLite` (or ETS-only for circuit
    snapshots).

### 17. Inspiration & Attribution (`~/git/hermes-agent`)

Several security, self-improvement, and embedded-persistence designs in §§14–16 were
inspired by patterns in Nous Research's Hermes Agent (`~/git/hermes-agent`) and adapted
idiomatically to Elixir/OTP and Pincer's Hexagonal Boundaries:

1. **Isolated Execution & Conformance (`~/git/hermes-agent/tools/environments/{base,docker,ssh,sandbox_conformance}.py`)** → Inspired `Pincer.Ports.Sandbox`, hardened `Docker` container flags (`--cap-drop ALL`, `no-new-privileges`, bounded `/tmp` & `/var/tmp` tmpfs mounts, default `--network none`, Docker/Podman detection, sanitized tracking labels), hardened `SSH` validation/ControlMaster patterns, and the shared `Pincer.Test.Support.SandboxConformance` contract suite.
2. **Skill Validation & Threat Guard (`~/git/hermes-agent/tools/{skills_guard,skill_manager_tool}.py`)** → Inspired `Pincer.Core.Skills.Guard` threat categories (`exfiltration`, `destructive`, `persistence`, `injection`, invisible Unicode chars) with loopback exemptions and descriptive-prose safeguards, slug/size budgets, atomic temp-file writes, and fail-closed gating for agent-authored skills generated by `Pincer.Core.Skills.Generator`.
3. **Embedded SQLite & FTS5 Persistence (`~/git/hermes-agent/persistence/sqlite/{_schema_ddl,_backend}.py`)** → Inspired `Pincer.Infra.SQLite` WAL/busy-timeout pragmas, idempotent startup DDL, FTS5 virtual tables kept synchronized via triggers/mutations, and safe FTS5 query tokenization/quoting in `Pincer.Storage.Adapters.SQLite`.

### 18. Index Purge & Config Atom Allowlist

Follow-up hardening for the single SQLite backend:

- **`Pincer.Ports.Storage.purge_invalid_documents/1`**:
  - Contract: `purge_invalid_documents(prefixes :: [String.t()]) :: {:ok, non_neg_integer()} | {:error, term()}` (default prefixes `["tmp/", "workspaces/"]`).
  - `Pincer.Storage.Adapters.SQLite` executes atomically inside `Pincer.Infra.SQLite.transaction/2`, removing matching `document` rows in `nodes` (`json_extract(data, '$.path') LIKE ... ESCAPE '!'`) **and** corresponding entries in `documents_fts` so no orphan FTS5 records remain.
  - `Mix.Tasks.Pincer.PurgeIndices` delegates to `Pincer.Ports.Storage` rather than coupling directly to the storage module.
- **`Pincer.Infra.Config` Atom Allowlists**:
  - `load/1` maps YAML top-level keys only through an explicit `@allowed_top_level_keys` table; unknown keys log a warning and are ignored without calling `String.to_atom/1`.
  - `storage` keys are filtered through `@allowed_storage_keys` (`adapter`, `path`, `vec`, `vec_path`, `vec_dimensions`); unknown keys log a warning and are ignored.

### 19. SQLite Onboarding & Diagnostics

Extends `setup`, `onboard`, `doctor`, and user documentation so Pincer can be bootstrapped
and validated without any external database or Docker dependency:

- **`Pincer.Infra.SQLite.health_check/0`**:
  - Opens an in-memory SQLite3 connection (`:memory:`), creates and drops a temporary
    `fts5` virtual table, and closes the connection cleanly, returning `:ok` or
    `{:error, reason}`.
- **Storage Resolution (`mix pincer.setup` & `mix pincer.onboard`)**:
  - Flags: `--storage sqlite` (only valid value), `--sqlite-path <path>`
    (default `"data/pincer.db"`), and `--config <path>` (default `"config.yaml"`).
  - Precedence when `--storage` is omitted: `PINCER_STORAGE` env var > configured
    `storage.adapter` in `--config` / `config.yaml` > `"sqlite"` default.
  - `mix pincer.setup` initializes the SQLite file, forwards `--sqlite-path` and
    `--config` to `mix pincer.onboard`, and runs idempotent schema initialization.
  - `Pincer.Core.Onboard.Defaults.defaults/1` emits `storage: {adapter: "sqlite", path: ...}`
    and `sandbox: {adapter: "local"}` without requiring a `database` block.
  - `Pincer.Core.Onboard.Preflight` validates `storage.path` writability (rejecting empty
    strings, `..` traversal segments, and non-directory/file parents) and uses
    `SQLite.health_check/0` in `check_db_connectivity/1`.
- **Diagnostics (`Pincer.Core.Doctor`)**:
  - Adds `storage_checks` emitting `:storage_backend` (`:ok`), `:sqlite_path` (`:ok` / `:error`),
    and `:sqlite_engine` (`:ok` / `:error`), plus `sqlite-vec` loadability reported
    separately so a missing extension is a warning, not a failure.

### 20. E2E Verification & CI Posture Gates

Consolidates real end-to-end verification and continuous security/health posture enforcement:

- **SQLite Test & Smoke Boot (`test/test_helper.exs` + `sqlite-smoke` CI job)**:
  - `config/test.exs` sets `PINCER_STORAGE=sqlite` and `PINCER_SQLITE_PATH=:memory:`;
    `test/test_helper.exs` deletes `tmp/test_workspaces` and starts ExUnit, with no
    database creation or migrations. `:sqlite_smoke` tests run in the normal suite and
    verify `StartupGuard.run/0`, `Pincer.Application` supervision, `Pincer.Ports.Storage`
    round-trips, FTS5 search, checkpoints, pairing state, and `PurgeIndices`.
  - Default `ExUnit.start/1` excludes opt-in `:docker`, `:bwrap`, `:chaos`, and `:stress`.
- **Opt-in Real Container E2E (`@tag :docker`)**:
  - `test/pincer/e2e/docker_sandbox_e2e_test.exs` runs `Pincer.Adapters.Sandbox.Docker.run/2`
    against `alpine:3.20` (executes via `mix test --only docker` or manual `workflow_dispatch`),
    asserting confined `/workspace` r/w, `--network none`, `CapEff: 0000000000000000`,
    `NoNewPrivs: 1`, `/tmp` `noexec` tmpfs, and workspace traversal rejection.
  - `Pincer.Adapters.Sandbox.Docker` maps non-root host workspace ownership via
    `--user <uid>:<gid>` by default (`run_as_host_user: true`, overridable via `:user` or
    `run_as_host_user: false`) so `/workspace` remains writable under `--cap-drop ALL`
    without granting `CAP_DAC_OVERRIDE`.
- **Full Introspection → Skills → Session E2E**:
  - Exercises `Session.Server`, `Introspection.Kernel`, `Skills.Generator`, `Skills.Guard`,
    `Skills.PromptIndex`, and `PromptAssembly` end-to-end on embedded SQLite, proving both
    dynamic prompt delivery to the LLM client on `{:kernel_skills_updated, skill}` and
    fail-closed blocking of dangerous skill payloads.
- **Continuous CI Posture Gates**:
  - Deterministic hardened fixture at `test/fixtures/ci_posture/config.yaml` verified by
    `mix pincer.doctor --strict` and `mix pincer.security_audit --strict` in CI.

### 21. Pre-Release Security Hardening

Closes shell-execution bypasses, sidecar PoC leaks, and unhardened defaults before public release:

- **Removal of `mcp.servers.shell` / `mcp_sidecar/` & Registry Defense-in-Depth**:
  - Removes `infrastructure/mcp/shell_server.py` (which executed unvalidated `subprocess.run(..., shell=True)`),
    the Node `mcp_sidecar/` PoC, and Python MCP venv installation from `Dockerfile` / `entrypoint.sh` / default `config.yaml`.
  - Default local sandbox uses `transport: "os"` (`Pincer.Adapters.Sandbox.Local`) behind `SafeShell` + `WorkspaceGuard`.
  - `Pincer.Adapters.NativeToolRegistry` filters and rejects `"run_command"` from external MCP tool catalogs.
- **`SafeShell` `find` & `git log` Hardening**:
  - `find` rejects destructive/exec/file-writing flags (`-delete`, `-exec`, `-execdir`, `-ok`, `-okdir`, `-fprint`, `-fprint0`, `-fprintf`, `-fls`) unless explicitly approved.
  - `git log` rejects `--output` / `--output=*`, `--ext-diff`, and `--textconv` unless explicitly approved.
- **Constant-Time Webhook Token Auth & Self-Contained Package**:
  - `Pincer.Channels.Webhook` (`packages/pincer_webhook`) verifies tokens using `:crypto.hash_equals/2` after length matching, owns `Pincer.Channels.Webhook.{Plug, Listener, RateLimiter}`, and exposes `extra_child_specs/1` so `Pincer.Channels.Factory` boots the listener polymorphically without hardcoded adapter checks.
- **Loopback Default for `/health` Endpoint**:
  - `Pincer.Adapters.Health.Plug.bind_ip/0` resolves `health_ip` / `PINCER_HEALTH_IP` and defaults `Bandit` to `{127, 0, 0, 1}`.

