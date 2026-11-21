# AGENTS.md - Pincer

Pincer is an Elixir/OTP framework that runs persistent AI agents: supervised per-user
sessions, an agentic tool-calling loop, MCP tool integration, PostgreSQL + pgvector (or
embedded SQLite) memory, and many messaging channels. Hexagonal architecture with
compile-time boundary enforcement.

`CLAUDE.md` and `GEMINI.md` mirror parts of this file inconsistently (GEMINI.md still
mentions SQLite-only storage and `Pincer.Tools.SafeShell`, which is stale); treat this
file as authoritative. `CONTRIBUTING.md` holds the PR-facing checklist.

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

**Reconcile the task list whenever you close a cycle.** After finishing a step, a
commit, or a shift in plan, re-read the todo list and update it before continuing: mark
what is done, add what the work revealed, and drop what no longer applies. The list is
the working record of a multi-step task - leaving it stale means the next agent (or the
next turn) cannot tell what still needs doing.

---

## 2. Commands

```bash
# Prereqs: PostgreSQL + pgvector for the default test path.
docker compose up -d postgres

mix deps.get
mix ecto.create && mix ecto.migrate

mix qa                      # format --check-formatted + compile --warnings-as-errors + test (--max-failures 1)
mix sprint.check            # same gate, but full test run (no --max-failures)
mix test --warnings-as-errors
mix test.quick              # --stale --max-failures 1
mix test test/pincer/core/executor_test.exs          # single file
mix test test/foo_test.exs:42                        # single test
mix format

mix pincer.setup            # first-run: deps, DB, migrate, wizard, health check (--storage sqlite --yes for zero-infra)
mix pincer.chat             # interactive CLI agent
mix pincer.server [channels]
mix pincer.agent new <id> | pair <id>
mix pincer.onboard | doctor [--strict] [--config path] | security_audit [--strict] [--config path]
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

**Postgres-free runs:** with `PINCER_STORAGE=sqlite` (aliases `sqlite3`;
`PINCER_SQLITE_PATH` selects the file, default `data/pincer.db`), `test_helper.exs` skips
all Ecto setup entirely and `:sqlite_smoke` tags get included. This is how CI runs the
zero-infra job:

```bash
PINCER_STORAGE=sqlite PINCER_SQLITE_PATH=tmp/ci_smoke.db PINCER_DB_PORT=1 \
  mix test --warnings-as-errors \
    test/pincer/e2e/zero_infra_sqlite_boot_e2e_test.exs \
    test/pincer/e2e/introspection_skills_e2e_test.exs \
    test/pincer/e2e/ci_posture_fixture_test.exs
```

CI (`.github/workflows/ci.yml`) additionally gates on posture checks that need no
database; run them after touching config, onboarding, or security code:

```bash
OPENROUTER_API_KEY=ci-posture-check mix pincer.doctor --strict --config test/fixtures/ci_posture/config.yaml
OPENROUTER_API_KEY=ci-posture-check mix pincer.security_audit --strict --config test/fixtures/ci_posture/config.yaml
```

**The WhatsApp package is gated.** `pincer_whatsapp` ships a custom Mix compiler that
shells out to `go build` (Go 1.21+), so it is only a dep when `PINCER_WHATSAPP=1` (see
`whatsapp_envs/0` in `mix.exs`). It is excluded from `:test` by default; CI runs it as a
separate job.

```bash
PINCER_WHATSAPP=1 mix test --warnings-as-errors \
  test/pincer/channels/whatsapp_test.exs \
  test/pincer/channels/whatsapp_session_test.exs \
  test/pincer/channels/whatsapp_bridge_test.exs
```

Toolchain: `mise.toml` pins Elixir 1.19.5 / OTP 27 (plus Go); `.tool-versions` and CI use
Elixir 1.18 / OTP 27.2; `mix.exs` only requires `~> 1.14`.

**Pick the bash execution mode per call.** The bash tool blocks for 60 seconds by
default; that threshold is a per-call parameter (`auto_background_after`), not a global
Crush setting, so there is nothing to configure once:

| Command | Mode |
|---|---|
| Known-trivial (`git status`, `grep`, `ls`, `wc`) | synchronous |
| Unknown duration | `auto_background_after: 10` |
| Known-slow (`mix test`, `mix compile --force`, repo-wide scans) | `run_in_background: true` |

Read results with `job_output` (`wait: true` when the result is the next step) and stop
runaway jobs with `job_kill`; do not assume a command finished because the call returned.
`Esc` cancels a running command (`Ctrl-C` only opens the quit dialog), which is why
synchronous mode is acceptable for the trivial cases.

Commands that read stdin (password prompts, `sudo`, interactive generators) obey neither
the timer nor `Esc`, because the process stays alive waiting for input. Never start one.

Always scope expensive commands: wrap loops in `timeout <seconds>`, and never start an
unbounded scan such as `find /` - it burns the whole turn for no result.

---

## 3. Configuration model

Three surfaces; only two carry real runtime values:

| Surface | Contains |
|---|---|
| `config/config.exs` + `config/{dev,test,prod}.exs` | Compile-time defaults: Ecto repo, the `:llm_providers` map (adapter module, `env_key`, `default_model`), `:storage_adapter`, `:sandbox_adapter`, executor tunables, retry/circuit-breaker knobs, logger format. |
| `config.yaml` (repo root) | **Runtime** config loaded by `Pincer.Infra.Config.load/0` at boot: `channels`, `database`, `storage`, `llm.provider` + per-provider `base_url`/`default_model`, `introspection`, `model_router`, `mcp.servers`, `gateway.bind`, `sandbox`, `tools.restrict_to_workspace`. This is how you enable/disable channels and switch providers. |
| `.env` | Secrets only (API keys, bot tokens), loaded by `dotenvy`; highest precedence. Copy `.env.example`. |

Adding an LLM provider means touching **both** places: an `:llm_providers` entry in
`config/config.exs` (adapter module + `env_key` + `default_model`) and an `llm.<name>`
block in `config.yaml` when it needs a `base_url`/`default_model`. Provider modules are
named `Pincer.LLM.Providers.*` and live in `packages/pincer_*`, not under `lib/`.

Precedence rules that bite:

- **Storage backend** = `PINCER_STORAGE` > `config.yaml` `storage.adapter` >
  `database.adapter` > `:postgres` (`Pincer.Infra.Config.configure_storage_adapter/2`).
- **Default LLM provider** = `config.yaml` `llm.provider` overrides
  `config :pincer, :default_llm_provider` (shipped config.yaml uses `groq`).
- Database overrides: `PINCER_DB_HOST/PORT/USER/PASSWORD/NAME/POOL_SIZE/SSL`.
- Health endpoint bind: `PINCER_HEALTH_IP` (or `:health_ip` app env) and the
  `:health_port` app env (default 127.0.0.1:4001; tests set `health_port: 0`).
- Channel secrets are indirect: each channel entry names a `token_env` /
  `*_env` variable that points at the env var holding the secret (for example
  `token_env: "TELEGRAM_BOT_TOKEN"`), so tests can swap the variable name.

`Pincer.Core.StartupGuard` compares `Ecto.Migrator` counts (migrations live in
`priv/repo/migrations`, timestamped `.exs`) and refuses to boot with pending migrations.

---

## 4. Architecture and boundaries

```
Pincer.Mix        (top-level, `top_level?: true`, `check: [in: false, out: false]`)
Pincer.Channels  ->  Pincer.Adapters  ->  Pincer.Core  ->  Pincer.Ports  ->  Pincer.Infra (+ Pincer.Utils)
```

Declared in each layer's root module (`lib/pincer/core.ex`, `adapters.ex`, `ports.ex`,
`channels.ex`, `infra.ex`, `llm.ex`, `utils.ex`) via `use Boundary, deps: [...], exports: [...]`.
Verified exports: `Infra` exports `PubSub, Config, Repo, SQLite, CircuitBreakerSnapshot`;
`Ports` exports `Messaging, Storage, LLM, MediaUnderstanding, ToolRegistry,
CapabilityDiscovery, Onboarding, UserMenu, Tool, Cron, Hook, Sandbox`; `Channels` exports
nothing (it consumes Core, not the reverse).

- `Core` may depend only on `Ports`, `Infra`, `Utils`.
- `Ports` may depend only on `Infra`.
- `Adapters` may depend on `Core`, `Ports`, `Infra`, `Utils`.
- `LLM` is a peer layer: `deps: [Pincer.Core, Pincer.Infra, Pincer.Ports]`.
- **In `exports` lists use relative aliases** (`Session.Server`), not owner-prefixed names.
  `test/pincer/boundary_exports_test.exs` enforces this for `core.ex`, `core/ux.ex`,
  `infra.ex`, `ports.ex` and also asserts **no `lib/pincer/core/**` file references
  `Pincer.Adapters.Tools*` / `SafeShell` directly** - Core must go through the
  `Pincer.Ports.ToolRegistry` port. Extend that test when you add a new boundary owner.
- Any `Pincer.Core.*` module used from `Channels`/`Adapters` must be listed in
  `lib/pincer/core.ex`'s `exports`, otherwise the boundary plugin emits a warning and the
  compile fails.
- Mix tasks live in `Mix.Tasks.Pincer.*` and carry `use Boundary, classify_to: Pincer.Mix`.
- `html_entities` is mapped to `Pincer.Utils` (`boundary: [externals: ...]` in `mix.exs`);
  HTML entity decoding lives in `Pincer.Adapters.Tools.Web.HtmlEntities`, not a top-level
  `HtmlEntities` module.

### Key runtime flow

1. `Pincer.Application` boots the supervision tree: `Cluster.Supervisor`, PromEx, PubSub,
   `Orchestration.Blackboard`, sub-agent DynamicSupervisor, observability, `Finch`,
   storage child (Repo or SQLite), `Heartbeat`, MCP supervisor + `MCP.Manager`,
   Introspection Kernel, Session/Project Horde registries and supervisors,
   `CircuitBreaker`, `RateLimiter`, `HookDispatcher`, `Session.Supervisor`,
   `Cron.Scheduler`, `TimerServer`, `Channels.Supervisor`, and a `Bandit` health endpoint.
2. `Pincer.Channels.Factory` reads `config.yaml` `channels` and resolves the adapter
   string (e.g. `"Pincer.Channels.Telegram"`) to a module; `Channels.Supervisor` starts
   one supervisor per enabled channel.
3. The channel maps sender -> agent workspace -> `Pincer.Core.Session.Server` (unique per
   user, Horde-registered), which calls `Pincer.Core.Executor.run/4`.
4. `Executor` assembles the prompt (`PromptAssembly`, memory recall, `Session.Pruner`),
   calls `Pincer.LLM.Client` (provider dispatch, failover, `ModelRouter` tiers), executes
   tool calls via `Pincer.Ports.ToolRegistry` (`Adapters.NativeToolRegistry` = native tools
   **plus** dynamically discovered MCP tools), recurses, then
   `Orchestration.Archivist` consolidates memory.

Per-concern policies are separate small modules rather than conditionals inside
`Executor` - e.g. `TurnOutcomePolicy`, `ToolAnswerPatternPolicy`, `StreamingPolicy`,
`CircuitBreaker`, `RetryPolicy`, `ContextOverflowRecovery`, `SessionScopePolicy`,
`EmptyResponseRecoveryPolicy`, `StatusMessagePolicy` (helpers live in
`lib/pincer/core/executor/{ctx,tool_call,tool_runner,loop_guard,stream_accumulator}.ex`).
Extend those instead of growing `Executor`.

---

## 5. Tools, channels, plugins, packages

**Tools** implement `Pincer.Ports.Tool` (`spec/0` returning JSON Schema, `execute/1` or
`execute/2`). Adding a native tool requires both steps:

1. `lib/pincer/adapters/tools/<name>.ex` + `test/pincer/tools/<name>_test.exs`.
2. Register the module in `@native_tools` in `lib/pincer/adapters/native_tool_registry.ex`.
   Skipping this means the tool exists but the LLM never sees it.

`spec/0` may return a map or a **list** of specs (multi-action tools such as `safe_shell`,
`web`, `github`, `git_inspect` do); the registry normalizes both, so `execute_tool/3`
matches by walking every spec's `name`.

**Security in tools:** filesystem and shell work must go through
`Pincer.Core.WorkspaceGuard` (path confinement, `..` rejection, null-byte rejection,
symlink chain checks) and `Pincer.Adapters.Tools.SafeShell` (tokenized whitelist; rejects
`; | & $ <>` and backticks, multi-line or line-continuation payloads, `..`, >1024 chars;
returns `{:error, {:approval_required, cmd}}` otherwise). `Pincer.Adapters.Tools.Web`
implements SSRF protection (blocks localhost, private ranges, `169.254.169.254`, with
manual redirect validation). MCP tools named in `@blocked_mcp_tools` (e.g. `run_command`)
are dropped because they bypass these guards. Never add a tool that bypasses them, and
never point destructive shell/FS tests at the real repo root.

**Channels** implement `Pincer.Ports.Channel` and ship as Hex-ready projects under
`packages/`, each with `priv/pincer_plugin.yaml` (`id`, `kind: channel`, `adapter`,
`config_schema`). Manifests are discovered from `priv/plugins/*/pincer_plugin.yaml`
(monorepo mode, see `lib/pincer/plugin/manifest.ex`); `kind` is one of
`channel | storage | llm | tool`. Channel packages depend only on `pincer_ports` (pure
behaviours) and `pincer_shared`; they must not reach into root app internals. Their tests
live in the **root** `test/pincer/channels/`, not inside the package.

**Monorepo layout:** every LLM provider and channel is both a `path:` dep in root
`mix.exs` and a separately publishable Hex package. `scripts/hex_publish.sh` publishes
them in dependency order (`pincer_ports`, `pincer_shared`, `pincer_openai_compat`, then
providers, then channels). Bumping the root version or changing a public callback usually
requires touching the package's `mix.exs`/`CHANGELOG.md` too.

---

## 6. Testing conventions

- Mocks are centralized in `test/support/mocks.ex` (Mox): `Pincer.LLM.ClientMock` for
  `Pincer.LLM.Provider`, plus `Pincer.Channels.{Discord,Telegram,Slack}.APIMock`.
  `test/support/test_adapter.ex` is a no-op channel API used via `config :pincer,
  discord_api/telegram_api/slack_api` in `config/test.exs`.
- In `:test`, `:llm_providers` is replaced with a single `"test"` provider backed by
  `Pincer.LLM.ClientMock` (set in `test_helper.exs`, not `config/test.exs`), and
  `:default_llm_provider` is `"test"`.
- Provider doubles use `use Pincer.Test.Support.LLMProviderDefaults` for
  `list_models/1`, `transcribe_audio/3`, `generate_embedding/3`.
- Test config disables heavy subsystems: `workspaces_dir: "tmp/test_workspaces"`,
  `enable_graph_watcher: false`, `enable_heartbeat_watchers: false`, `health_port: 0`.
  Put new background watchers behind similar flags.
- Ecto sandbox is enabled (`pool: Ecto.Adapters.SQL.Sandbox`), but nothing checks out
  automatically. Tests touching Postgres do `Application.ensure_all_started(:pincer)`,
  then `:ok = Ecto.Adapters.SQL.Sandbox.checkout(Pincer.Infra.Repo)` and clean tables
  explicitly in `setup` (see `test/mix/tasks/pincer.memory.report_test.exs`).
- ExUnit excludes `:docker` always, and `:sqlite_smoke` unless in SQLite mode. Only `:chaos`
  and `:stress` tags exist besides those; run them explicitly (`--only chaos`).
- `test/fixtures/` holds on-disk fixtures (`file_system_workspace/`, `telegram/`, and
  `ci_posture/config.yaml` used by the CI posture gates);
  `test/bench/` holds Benchee scripts (not run by `mix test`; `benchee` is `only: :bench`);
  `test/load/` holds load helpers.

---

## 7. Gotchas

- **`config.yaml` is required at boot**; if missing, `Infra.Config.load/0` logs
  "Fatal error: Failed to load config.yaml". Docker bind-mounts it into `/app/config.yaml`.
  The committed one is intentionally neutral (CLI channel only, `model_router.enabled:
  false`, empty `mcp.servers`) - don't ship personal provider/channel settings in it.
- **Per-agent state lives in `workspaces/<agent_id>/.pincer/`** (identity, soul, memory,
  history). The repo-root `memory/`, `MEMORY.md`, `HISTORY.md`, `sessions/`, `logs/`,
  `tmp/`, `trash/` are runtime artifacts from running the agent - never treat them as
  project documentation or hand-edit them. `workspaces/` and `sessions/` are also mounted
  into the container.
- **Bootstrap ritual:** agents start without `IDENTITY`/`SOUL`; `BOOTSTRAP.md` drives the
  first conversation that forms the personality and is then deleted. Pre-seeding those
  files prevents the ritual from ever firing (`SPECS.md` §7).
- **Model router tiers need their own API keys** (`groq` local/fast, `z_ai` balanced,
  `z_ai_coding` powerful). A missing key fails at call time; disable with
  `model_router.enabled: false` in `config.yaml` (already the shipped default).
- **Embeddings:** OpenRouter default `baai/bge-m3` with one retry to
  `baai/bge-large-en-v1.5` on the "No successful provider responses." error. Both are
  1024-dim to keep the pgvector HNSW indexes valid (`20260410152102_add_hnsw_indexes`).
- **Port behaviour dispatch is indirect:** `Pincer.Ports.LLM` and friends expose wrapper
  functions that read `Application.get_env(:pincer, :llm_adapter | :storage_adapter |
  :sandbox_adapter)`. In tests, stub the adapter module or the Mox mock, not the port
  module itself.
- **Inter-agent messaging goes through `Core.Orchestration.Blackboard`** (ETS hot tier +
  disk journal cold tier at `memory/blackboard.journal`). A `nil` scope intentionally
  returns only global messages; don't "fix" it into a full read.
- **Sandbox execution** goes through `Pincer.Adapters.Sandbox.{Local,Docker,SSH}` selected
  by `sandbox.adapter` / `:sandbox_adapter`. `Local` can run over the tool registry, OS
  transport, or Docker; Docker-backed tests are tagged `:docker` and only run on
  `workflow_dispatch` CI using `alpine:3.20`.
- **Executor limits are compile-time config**, set in `config/config.exs`:
  `:max_recursion_depth`, `:tool_result_max_chars`, `:max_inline_bytes`,
  `:approval_timeout_ms`, `:fs_*`, `:llm_retry`, `:circuit_breaker_*`.
- `Nx`/`Bumblebee` are optional: `Pincer.AI.Embeddings` guards with
  `Code.ensure_loaded?/1` and degrades silently when absent.
- Several modules and docs still carry Portuguese `@moduledoc` text; match local style
  when editing an existing module, don't mass-translate.

---

## 8. Docs map

- `README.md` - user-facing overview, architecture diagrams, channel/provider tables.
- `SPECS.md` - env-var matrix per provider plus subsystem specs (Pruner, ModelRouter,
  CommandQueue, ContractEngine, Skills Manifest, Kernel, bootstrap ritual, embeddings).
- `CONTRIBUTING.md` / `SECURITY.md` - PR checklist and disclosure policy (CI enforces the
  doctor/security-audit posture).
- `CHANGELOG.md` - user-visible changes; add an entry for behavioral changes.
- `docs/architecture/`, `docs/SPECS/` - deeper design notes; `plans/`, `tasks/prd.json` -
  larger in-flight work; check before starting a big feature.
- `priv/pincer/templates/`, `workspaces/.template/.pincer/` - scaffolding for new agent
  workspaces; `fixtures/skills/` - skill fixture data.
