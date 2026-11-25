# AGENTS.md - Pincer

Pincer is an Elixir/OTP framework that runs persistent AI agents: supervised per-user
sessions, an agentic tool-calling loop, MCP tool integration, embedded SQLite (FTS5 plus
optional sqlite-vec) memory, and many messaging channels. Hexagonal architecture with
compile-time boundary enforcement.

Treat this file as the authoritative agent and contributor guide; `CONTRIBUTING.md`
holds the PR-facing checklist.

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
# Prereqs: Elixir 1.20.5 / OTP 27. No database service is required.
mix deps.get
./scripts/build_sqlite_vec.sh   # optional: native vector search (skipped → cosine fallback)

mix qa                      # format --check-formatted + compile --warnings-as-errors + test (--max-failures 1)
mix sprint.check            # same gate, but full test run (no --max-failures)
mix test --warnings-as-errors
mix test.quick              # --stale --max-failures 1
mix test test/pincer/core/executor_test.exs          # single file
mix test test/foo_test.exs:42                        # single test
mix format

mix pincer.setup            # first-run: deps, SQLite init, wizard, health check (--yes, --sqlite-path)
mix pincer.chat             # interactive CLI agent
mix pincer.server [channels]
mix pincer.agent new <id> | pair <id>
mix pincer.onboard | doctor [--strict] [--config path] | security_audit [--strict] [--config path]
mix pincer.memory.report | memory.explain | full_sync | purge_indices | plugins
```

**`mix test` uses embedded SQLite only.** `config/test.exs` sets
`PINCER_STORAGE=sqlite` and `PINCER_SQLITE_PATH=:memory:`; `test/test_helper.exs` clears
`tmp/test_workspaces`. There is no test database to create, drop, or migrate and no
external service to start. Tests run in parallel against in-memory SQLite; tests that
need durable storage create their own temp file under `tmp/`.

**sqlite-vec is optional.** `./scripts/build_sqlite_vec.sh` (needs `git`, `make`, `cc`)
writes `priv/sqlite_vec/vec0.so` and is version-pinned in the script. `PINCER_SQLITE_VEC=0`
disables loading; semantic search then uses in-process cosine similarity. `Dockerfile`
and CI run the build script.

**`:sqlite_smoke` tests are part of the normal suite** (SQLite is the only backend).
ExUnit excludes opt-in `:docker`, `:bwrap`, `:chaos`, and `:stress`.

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

Toolchain: `mise.toml`, `.tool-versions`, the Dockerfile, and CI pin Elixir 1.20.5 /
OTP 27.2 (plus Go); `mix.exs` requires `~> 1.20`. On a cold dependency build, compile
`plug` before the project (`mix deps.compile plug`): `telegex` uses `Plug.Router` but
declares `plug` as optional, so Mix can otherwise compile it too early. The Dockerfile
and CI do this explicitly.

**Every command sets `auto_background_after: 10`.** No exceptions, no categories, no
"trivial" case, and no distinction between tools: the tool blocks for 60 seconds by
default, and this per-call parameter is the only thing that lowers it. Every execution
carries it, so nothing can stall a turn for longer than ten seconds.

It is a per-call parameter, not a global Crush setting, so there is nothing to configure
once. When a command is expected to outlive that window (`mix test`, `mix compile --force`,
repo-wide scans) also pass `run_in_background: true` so it starts as a job immediately.

**Never wait on a job.** `job_output` is called without `wait: true` in every condition -
no "the result is the next step" case, no "nothing else to do" case, no trivial case.
`wait: true` is not valid for anything. If the result is needed before continuing, the
command was sized wrong, not the read.

**Never wait with `sleep`.** It is a synchronous stall in disguise and was the same
mistake wearing different clothes. Start the work as a job (or a subagent) and move on.

Both rules are enforced by a `PreToolUse` hook (`~/.config/crush/hooks/no-blocking-wait.sh`,
registered in `~/.config/crush/crush.json`), which blocks `job_output` carrying the wait
flag and any `bash` command that runs `sleep`. A blocked call means the rule was broken,
not that the hook is wrong - fix the command, do not work around the block. The hook logs
every intercepted tool input under `~/.config/crush/hooks/log/`, so a schema change shows
up as a visible mismatch instead of a silently-passing hook.

Extra tool calls are cheap here; a stalled turn is not. Never trade a background job for a
lower call count, and never shorten a safety check (`timeout`, scope limits) to save calls.

Read results with `job_output` (`wait: true` when the result is the next step) and stop
runaway jobs with `job_kill`; do not assume a command finished because the call returned.
`Esc` cancels a running command (`Ctrl-C` only opens the quit dialog).

Commands that read stdin (password prompts, `sudo`, interactive generators) obey neither
the timer nor `Esc`, because the process stays alive waiting for input. Never start one.

Always scope expensive commands: wrap loops in `timeout <seconds>`, and never start an
unbounded scan such as `find /` - it burns the whole turn for no result.

---

## 3. Configuration model

Three surfaces; only two carry real runtime values:

| Surface | Contains |
|---|---|
| `config/config.exs` + `config/{dev,test,prod}.exs` | Compile-time defaults: the `:llm_providers` map (adapter module, `env_key`, `default_model`), `:storage_adapter`, `:sqlite_path`, `:sandbox_adapter`, executor tunables, retry/circuit-breaker knobs, logger format. |
| `config.yaml` (repo root) | **Runtime** config loaded by `Pincer.Infra.Config.load/0` at boot: `channels`, `storage`, `llm.provider` + per-provider `base_url`/`default_model`, `introspection`, `model_router`, `mcp.servers`, `gateway.bind`, `sandbox`, `tools.restrict_to_workspace`. This is how you enable/disable channels and switch providers. |
| `.env` | Secrets only (API keys, bot tokens), loaded by `dotenvy`; highest precedence. Copy `.env.example`. |

Adding an LLM provider means touching **both** places: an `:llm_providers` entry in
`config/config.exs` (adapter module + `env_key` + `default_model`) and an `llm.<name>`
block in `config.yaml` when it needs a `base_url`/`default_model`. Provider modules are
named `Pincer.LLM.Providers.*` and live in `packages/pincer_*`, not under `lib/`.

Precedence rules that bite:

- **Storage backend** = `PINCER_STORAGE` > `config.yaml` `storage.adapter` > `"sqlite"`
  (`Pincer.Infra.Config` rejects `postgres`/`postgresql` with an `ArgumentError`).
- **SQLite path** = `PINCER_SQLITE_PATH` > `storage.path` > `"data/pincer.db"`; tests set
  `:memory:`.
- **sqlite-vec** = `storage.vec` / `PINCER_SQLITE_VEC` (`auto` by default),
  `storage.vec_path` / `PINCER_SQLITE_VEC_PATH`, and
  `storage.vec_dimensions` / `PINCER_SQLITE_VEC_DIMENSIONS` (default 1024).
- **Default LLM provider** = `config.yaml` `llm.provider` overrides
  `config :pincer, :default_llm_provider` (shipped config.yaml uses `groq`).
- Health endpoint bind: `PINCER_HEALTH_IP` (or `:health_ip` app env) and the
  `:health_port` app env (default 127.0.0.1:4001; tests set `health_port: 0`).
- Channel secrets are indirect: each channel entry names a `token_env` /
  `*_env` variable that points at the env var holding the secret (for example
  `token_env: "TELEGRAM_BOT_TOKEN"`), so tests can swap the variable name.

`Pincer.Core.StartupGuard` verifies SQLite storage is writable and, when vector search is
enabled, that `sqlite-vec` loads; there are no migrations or remote connection checks.

---

## 4. Architecture and boundaries

```
Pincer.Mix        (top-level, `top_level?: true`, `check: [in: false, out: false]`)
Pincer.Channels  ->  Pincer.Adapters  ->  Pincer.Core  ->  Pincer.Ports  ->  Pincer.Infra (+ Pincer.Utils)
```

Declared in each layer's root module (`lib/pincer/core.ex`, `adapters.ex`, `ports.ex`,
`channels.ex`, `infra.ex`, `llm.ex`, `utils.ex`) via `use Boundary, deps: [...], exports: [...]`.
Verified exports: `Infra` exports `PubSub, Config, SQLite, CircuitBreakerSnapshot`;
`Ports` exports `Messaging, Storage, LLM, MediaUnderstanding, ToolRegistry,
CapabilityDiscovery, Onboarding, UserMenu, Tool, Cron, Hook, Sandbox`; `Channels` exports
nothing (it consumes Core, not the reverse).

- `Core` may depend only on `Ports`, `Infra`, `Utils`.
- `Ports` may depend only on `Infra`.
- `Adapters` may depend on `Core`, `Ports`, `Infra`, `Utils`.
- `LLM` is a peer layer: `deps: [Pincer.Core, Pincer.Infra, Pincer.Ports, Pincer.Utils]`.
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
   storage child (`Pincer.Infra.SQLite`), `Heartbeat`, MCP supervisor + `MCP.Manager`,
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
  `enable_graph_watcher: false`, `health_port: 0`.
  Put new background watchers behind similar flags.
- Storage is the embedded SQLite adapter; there is no SQL sandbox and no checkout step.
  Tests that need isolation either use the `:memory:` connection from `config/test.exs`
  or start their own `Pincer.Infra.SQLite` on a temp file under `tmp/` and create the
  fixtures they read. See `test/pincer/e2e/zero_infra_sqlite_boot_e2e_test.exs`.
- ExUnit excludes `:docker`, `:bwrap`, `:chaos`, and `:stress`; `:sqlite_smoke` runs in
  the normal suite (SQLite is the only backend). Run excluded or integration
  tests explicitly (`--only chaos`, `--include bwrap` for the real bubblewrap test).
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
  1024-dim, matching `storage.vec_dimensions` (default 1024); when `sqlite-vec` is not
  loaded, search uses in-process cosine similarity so no index rebuild is needed.
- **Port behaviour dispatch is indirect:** `Pincer.Ports.LLM` and friends expose wrapper
  functions that read `Application.get_env(:pincer, :llm_adapter | :storage_adapter |
  :sandbox_adapter)`. In tests, stub the adapter module or the Mox mock, not the port
  module itself.
- **Inter-agent messaging goes through `Core.Orchestration.Blackboard`** (ETS hot tier +
  disk journal cold tier at `memory/blackboard.journal`). A `nil` scope intentionally
  returns only global messages; don't "fix" it into a full read.
- **Sandbox execution** goes through `Pincer.Adapters.Sandbox.{Local,Docker,SSH}` selected
  by `sandbox.adapter` / `:sandbox_adapter`. `Local` can run over the tool registry, OS
  transport, or the Linux-only bubblewrap transport (`bwrap: true` / `transport: "bwrap"`);
  Docker-backed tests are tagged `:docker` and only run on `workflow_dispatch` CI using
  `alpine:3.20`. The bwrap transport is fail-closed (StartupGuard refuses to boot when the
  probe fails) and still passes through `SafeShell` + `WorkspaceGuard`. Resource limits
  use `prlimit` (default: 1 GiB address space, 120 s CPU, 4096 pids, 1024 open files;
  `limits: :disabled` or a limit map replaces the defaults, with 0/absent disabling a
  single limit). The boot probe also checks `prlimit` availability. On Ubuntu 24.04+
  unprivileged user namespaces require the `bwrap-userns-restrict` AppArmor profile; the
  real integration test is tagged `:bwrap` (`mix test --include bwrap`).
- **Executor limits are compile-time config**, set in `config/config.exs`:
  `:max_recursion_depth`, `:tool_result_max_chars`, `:max_inline_bytes`,
  `:approval_timeout_ms`, `:fs_*`, `:llm_retry`, `:circuit_breaker_*`,
  `:tool_max_concurrency`, `:max_subagents`, `:max_subagents_per_session`,
  `:max_subagent_depth`, `:max_subagent_tree_tokens`, `:max_subagent_tree_ms`,
  `:curated_memory_limits`. Sub-agent runs persist their status to `checkpoints`
  (statuses `running`/`finished`/`failed`/`interrupted`) and `dispatch_agent`
  exposes them through its `status` action. Sub-agents may nest up to
  `:max_subagent_depth`; only `dispatch_agent` is auto-approved inside a
  sub-agent, and each tree is bounded by a token budget and wall-clock deadline
  enforced at spawn time.
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
