# AGENTS.md - Pincer

Pincer is an Elixir/OTP framework that runs persistent AI agents: supervised per-user
sessions, an agentic tool-calling loop, MCP tool integration, PostgreSQL + pgvector
memory, and many messaging channels. Hexagonal architecture with compile-time boundary
enforcement.

`CLAUDE.md` and `GEMINI.md` mirror parts of this file; treat this one as authoritative.

---

## 1. Development protocol (mandatory)

Doc-First + TDD:

1. **Spec first** - document the interface (in `SPECS.md` or the task plan) before code.
2. **Red -> Green -> Refactor** - write the failing test in `test/.../foo_test.exs`, then
   the minimum implementation, then improve.
3. **No `.ex` without a matching `.exs` test.**
4. **Acceptance:** `@moduledoc`/`@doc` present, happy path + error path tested,
   `mix format` clean.

Warnings are errors everywhere: `elixirc_options: [warnings_as_errors: true]` in
`mix.exs`, so an unused variable or a boundary violation fails the build.

---

## 2. Commands

```bash
# Prereqs: PostgreSQL + pgvector is required for ANY test run.
docker compose up -d postgres

mix deps.get
mix ecto.create && mix ecto.migrate

mix qa                      # format --check-formatted + compile --warnings-as-errors + test (--max-failures 1)
mix sprint.check            # same gate, but full test run (no --max-failures)
mix test --warnings-as-errors
mix test.quick              # --stale only
mix test test/pincer/core/executor_test.exs          # single file
mix test test/foo_test.exs:42                        # single test
mix format

mix pincer.setup            # first-run: deps, DB, migrate, wizard, health check
mix pincer.chat             # interactive CLI agent
mix pincer.server [channels]
mix pincer.agent new <id> | pair <id>
mix pincer.onboard | doctor [--strict] | security_audit [--strict]
mix pincer.memory.report | memory.explain | full_sync | purge_indices | plugins
```

**`mix test` drops and recreates the test database on every run.** `test/test_helper.exs`
runs `ecto.drop`, `ecto.create`, `ecto.migrate`, then deletes `tmp/test_workspaces`.
Never point `PINCER_DB_NAME` at the dev/prod database when testing.

**The database you connect to must have a `postgres` role.** `Pincer.Core.StartupGuard`
runs before the supervision tree; if credentials do not match, boot aborts with a
`DBConnection` checkout error. When `docker compose` cannot bind 127.0.0.1:5432 because a
host PostgreSQL already holds the port, the container starts but is unreachable and the app
reports `role "postgres" does not exist`. Run against the reachable instance instead:

```bash
PINCER_DB_USER=<user> PINCER_DB_PASSWORD=<pass> mix test --warnings-as-errors
```

In `:test` the guard's DB/migration checks are skipped via
`config :pincer, skip_startup_guard: true` (`config/test.exs`); `test_helper.exs` owns DB
creation. Side effect: `mix ecto.create` is a no-op under `MIX_ENV=test` unless the
`PINCER_DB_USER`/`PINCER_DB_PASSWORD` you pass actually match the server.

**The WhatsApp package is gated.** `pincer_whatsapp` ships a custom Mix compiler that
shells out to `go build`, so it is only a dep when `PINCER_WHATSAPP=1` (see
`whatsapp_envs/0` in `mix.exs`). It is excluded from `:test` by default; CI runs it as a
separate job.

```bash
PINCER_WHATSAPP=1 mix test --warnings-as-errors \
  test/pincer/channels/whatsapp_test.exs \
  test/pincer/channels/whatsapp_session_test.exs \
  test/pincer/channels/whatsapp_bridge_test.exs
```

---

## 3. Configuration model

Three surfaces; only two carry real runtime values:

| Surface | Contains |
|---|---|
| `config/config.exs` + `config/{dev,test,prod}.exs` | Compile-time defaults: Ecto repo, the `:llm_providers` map (adapter module, `env_key`, `default_model`), executor tunables, retry/circuit-breaker knobs, logger format. |
| `config.yaml` (repo root) | **Runtime** config loaded by `Pincer.Infra.Config.load/0` at boot: `channels`, `database`, `llm.provider` + per-provider `base_url`/`default_model`, `introspection`, `model_router`, `mcp.servers`, `tools.restrict_to_workspace`. This is how you enable/disable channels and switch providers. |
| `.env` | Secrets only (API keys, bot tokens), loaded by `dotenvy`; highest precedence. |

Adding an LLM provider means touching **both** places: an `:llm_providers` entry in
`config/config.exs` (adapter module + `env_key`) and an `llm.<name>` block in
`config.yaml` when it needs a `base_url`. Database overrides:
`PINCER_DB_HOST/PORT/USER/PASSWORD/NAME/POOL_SIZE/SSL`.

`Pincer.Core.StartupGuard` compares `Ecto.Migrator` counts (migrations live in
`priv/repo/migrations`) and refuses to boot with pending migrations.

---

## 4. Architecture and boundaries

```
Pincer.Mix   (top-level, `check: [in: false, out: false]` - all Mix tasks live here)
Pincer.Channels  ->  Pincer.Adapters  ->  Pincer.Core  ->  Pincer.Ports  ->  Pincer.Infra
```

Declared in each layer's root module (`lib/pincer/core.ex`, `adapters.ex`, `ports.ex`) via
`use Boundary, deps: [...], exports: [...]`.

- `Core` may depend only on `Ports`, `Infra`, `Utils`.
- `Ports` may depend only on `Infra`.
- `Adapters` may depend on `Core`, `Ports`, `Infra`, `Utils`.
- **In `exports` lists use relative aliases** (`Session.Server`), not fully-qualified names.
- Any `Pincer.Core.*` module used from `Channels`/`Adapters` must be listed in
  `lib/pincer/core.ex`'s `exports`, otherwise the boundary plugin emits a warning and the
  compile fails.
- Mix tasks live in `Mix.Tasks.Pincer.*` and carry `use Boundary, classify_to: Pincer.Mix`.
- `html_entities` is mapped to `Pincer.Utils` in `mix.exs`.

### Key runtime flow

1. `Pincer.Application` boots the supervision tree (`Infra.PubSub`, `Finch`,
   `Infra.Repo`, Heartbeat, Dispatcher, `MCP.Supervisor` -> `MCP.Manager`,
   `Session.Registry`/`Session.Supervisor`, `Cron.Scheduler`, `Channels.Supervisor`,
   dev-only `Reloader`).
2. `Pincer.Channels.Factory` reads `config.yaml` `channels` and resolves the adapter
   string (e.g. `"Pincer.Channels.Telegram"`) to a module; `Channels.Supervisor` starts
   one supervisor per enabled channel.
3. The channel maps sender -> agent workspace -> `Pincer.Core.Session.Server` (unique per
   user, Horde-registered), which calls `Pincer.Core.Executor.run/4`.
4. `Executor` assembles the prompt (`PromptAssembly`, memory recall, `Session.Pruner`),
   calls `Pincer.LLM.Client` (provider dispatch, failover, `ModelRouter` tiers), executes
   tool calls via `Pincer.Ports.ToolRegistry` (`Adapters.NativeToolRegistry` = native tools
   **plus** dynamically discovered MCP tools), recurses, then the Archivist consolidates
   memory.

Per-concern policies are separate small modules rather than conditionals inside
`Executor` - e.g. `TurnOutcomePolicy`, `ToolAnswerPatternPolicy`, `StreamingPolicy`,
`CircuitBreaker`, `RetryPolicy`, `ContextOverflowRecovery`, `SessionScopePolicy`. Extend
those instead of growing `Executor`.

---

## 5. Tools, channels, plugins

**Tools** implement `Pincer.Ports.Tool` (`spec/0` returning JSON Schema, `execute/1` or
`execute/2`). Adding a native tool requires both steps:

1. `lib/pincer/adapters/tools/<name>.ex` + `test/pincer/tools/<name>_test.exs`.
2. Register the module in `@native_tools` in `lib/pincer/adapters/native_tool_registry.ex`.
   Skipping this means the tool exists but the LLM never sees it.

`spec/0` may return a map or a **list** of specs (multi-action tools such as `safe_shell`,
`web`, `github` do); the registry normalizes both.

**Security in tools:** filesystem and shell work must go through
`Pincer.Core.WorkspaceGuard` (path confinement, `..` rejection, symlink chain checks) and
`Pincer.Adapters.Tools.SafeShell` (tokenized whitelist; rejects `; | & $ <>`, multi-line
or line-continuation payloads and `..`; returns `{:error, {:approval_required, cmd}}`
otherwise). `Pincer.Adapters.Tools.Web` implements SSRF protection (blocks localhost,
private ranges, `169.254.169.254`, with manual redirect validation). Never add a tool that
bypasses these.

**Channels** implement `Pincer.Ports.Channel` and ship as Hex-ready projects under
`packages/`, each with `priv/pincer_plugin.yaml` (`id`, `kind: channel`, `adapter`,
`config_schema`). Manifests are discovered from `priv/plugins/*/pincer_plugin.yaml`
(monorepo mode, see `lib/pincer/plugin/manifest.ex`). Channel packages depend only on
`pincer_ports` (pure behaviours) and `pincer_shared`; they must not reach into root app
internals. Their tests live in the **root** `test/pincer/channels/`, not inside the package.

**LLM providers** live in root `lib/pincer/llm/providers/`; most wrap `OpenAICompat`, are
registered in `config/config.exs`, and are backed by the `packages/pincer_*` path deps.

---

## 6. Testing conventions

- Mocks are centralized in `test/support/mocks.ex` (Mox): `Pincer.LLM.ClientMock` for
  `Pincer.LLM.Provider`, plus `Discord/Telegram/Slack.APIMock`.
- In `:test`, `:llm_providers` is replaced with a single `"test"` provider backed by
  `Pincer.LLM.ClientMock`, and `:default_llm_provider` is `"test"`.
- Provider doubles use `use Pincer.Test.Support.LLMProviderDefaults` for
  `list_models/1`, `transcribe_audio/3`, `generate_embedding/3`.
- Test config disables heavy subsystems: `workspaces_dir: "tmp/test_workspaces"`,
  `enable_graph_watcher: false`, `enable_heartbeat_watchers: false`, `health_port: 0`.
  Put new background watchers behind similar flags.
- `test/fixtures/` holds on-disk fixtures; `test/bench/` holds Benchee scripts (not run by
  `mix test`; `benchee` is `only: :bench`). Ecto sandbox is enabled
  (`pool: Ecto.Adapters.SQL.Sandbox`).

---

## 7. Gotchas

- **`config.yaml` is required at boot**; if missing, `Infra.Config.load/0` logs
  "Fatal error: Failed to load config.yaml". Docker bind-mounts it into `/app/config.yaml`.
- **Per-agent state lives in `workspaces/<agent_id>/.pincer/`** (identity, soul, memory,
  history). The repo-root `memory/` and `MEMORY.md`/`HISTORY.md` are runtime artifacts from
  running the agent - never treat them as project documentation or hand-edit them.
- **Bootstrap ritual:** agents start without `IDENTITY`/`SOUL`; `BOOTSTRAP.md` drives the
  first conversation that forms the personality and is then deleted. Pre-seeding those
  files prevents the ritual from ever firing (`SPECS.md` §7).
- **Model router tiers need their own API keys** (`groq` local/fast, `z_ai` balanced,
  `z_ai_coding` powerful). A missing key fails at call time; disable with
  `model_router.enabled: false` in `config.yaml`.
- **Embeddings:** OpenRouter default `baai/bge-m3` with one retry to
  `baai/bge-large-en-v1.5` on the "No successful provider responses." error. Both are
  1024-dim to keep the pgvector HNSW indexes valid.
- **Inter-agent messaging goes through `Core.Orchestration.Blackboard`** (ETS hot tier +
  disk journal cold tier at `memory/blackboard.journal`). A `nil` scope intentionally
  returns only global messages; don't "fix" it into a full read.
- **Executor limits are compile-time config**, set in `config/config.exs`:
  `:max_recursion_depth`, `:tool_result_max_chars`, `:max_inline_bytes`,
  `:approval_timeout_ms`, `:fs_*`, `:llm_retry`, `:circuit_breaker_*`.
- `Nx`/`Bumblebee` are optional: `Pincer.AI.Embeddings` guards with
  `Code.ensure_loaded?/1` and degrades silently when absent.
- Toolchain is pinned by `mise.toml` (Elixir 1.19.5 / OTP 27); CI uses 1.18 / 27.2 while
  `mix.exs` only requires `~> 1.14`.

---

## 8. Docs map

- `README.md` - user-facing overview, architecture diagrams, channel/provider tables.
- `SPECS.md` - env-var matrix per provider plus subsystem specs (Pruner, ModelRouter,
  CommandQueue, ContractEngine, Skills Manifest, Kernel, bootstrap ritual, embeddings).
- `plans/`, `tasks/prd.json` - larger in-flight work; check before starting a big feature.
- `priv/pincer/templates/`, `workspaces/.template/.pincer/` - scaffolding for new agent
  workspaces.
