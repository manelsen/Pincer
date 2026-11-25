# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Port dispatch requires configured adapters. In particular, missing or invalid `:sandbox_adapter` application configuration raises an explicit error. The application config still selects the local sandbox by default.
- Storage is SQLite-only: PostgreSQL/pgvector support, Ecto, `Ecto.Repo`, migrations, `mix ecto.*` setup, `PINCER_DB_*` overrides, and the Postgres test path are removed. Models are plain structs validated by `Pincer.Utils.Validation`; `storage.adapter` accepts only `"sqlite"` (PostgreSQL is rejected at boot) and the full test suite runs on in-memory SQLite with no external database service.
- `.env.example` documents the `PINCER_SQLITE_*` knobs instead of `PINCER_DB_*`, and the `priv/profiles/*.yaml` templates now ship a `storage:` block with a per-profile SQLite file instead of the old database URL block.
- Require Elixir 1.20.5 / OTP 27 across `mix.exs`, mise/asdf, the Docker image, and CI. Remove compiler warnings surfaced by 1.20 (unused `require Logger` and unreachable/redundant clauses) so `warnings_as_errors` stays clean.

### Added
- Optional `sqlite-vec` semantic search, loaded from `priv/sqlite_vec/vec0.so` (built by `./scripts/build_sqlite_vec.sh`, version pinned in the script). Configure with `storage.vec` / `storage.vec_path` / `storage.vec_dimensions` or `PINCER_SQLITE_VEC*`; when the extension is absent or disabled, search falls back to in-process cosine similarity.
- The local sandbox adapter can run commands over a Linux-only bubblewrap transport (`transport: "bwrap"` or `bwrap: true`): a minimal read-only root, workspace bind, network `none`/`host`, `prlimit`-based memory/CPU/PID/file limits, a capability probe cached per executable, and fail-closed startup via `StartupGuard.check_sandbox/0`.
- The `pincer_webhook` channel now runs an HTTP listener (Bandit + Plug) under the channels supervisor, configurable with `bind` (loopback by default), `port`, `path`, `max_body_bytes`, and `rate_limit_per_minute`; deliveries are token-gated and validated before ingestion.
- The Feishu/Lark channel now has an inbound webhook listener (Bandit + Plug): fail-closed signature verification with the encrypt key, encrypted payload decryption, URL-verification challenges, per-chat session startup, and inbound message routing. Configure under `channels.feishu.webhook`.
- LINE and DingTalk now have inbound webhook listeners and per-chat session workers, with signature verification, message parsing, resolver-backed routing, and channel-configured signing secrets. Configure under `channels.line.webhook` and `channels.dingtalk.webhook`.
- Webhook ingress is rate limited per client IP (60 requests/minute by default, `0` disables) with `429` + `Retry-After`; an unavailable limiter fails closed with `503`.
- The security audit warns when an enabled webhook binds to all interfaces (`0.0.0.0`, `::`).
- `read_blackboard` honors `limit` (default 10, capped at 100) and returns only the most recent messages.
- Project state is durable across restarts: independent `Project.Server` runs persist their plan, task index, status, and retry state in SQLite, active runs are rehydrated at boot, and the `/project` wizard reloads from storage after ETS loss. `/project list` and `/project status <id>` expose persisted projects.
- Sub-agent runs persist a running checkpoint every 10 tool uses, so `dispatch_agent`'s `status` action reports progress before termination.
- `dispatch_agent` accepts per-run `provider`, `model`, and `thinking_level`, a `status` action that reads an agent's durable checkpoint run record, and enforces `:max_subagents` / `:max_subagents_per_session` caps before starting a child.
- Sub-agents can dispatch nested sub-agents up to `:max_subagent_depth` (default 2); `dispatch_agent` is auto-approved inside a sub-agent, per-session caps are charged against the tree's root session, and depth/root are stored in checkpoint metadata.
- Each sub-agent tree has a per-root token budget (`:max_subagent_tree_tokens`, default 200 000) and wall-clock deadline (`:max_subagent_tree_ms`, default 30 min), checked when a dispatch is admitted; running agents are not interrupted.
- `session_search` native tool with `discover`, `search`, and `read` actions over persisted session transcripts and storage search.
- Curated memory (`MEMORY.md`, `USER.md`) is bounded by `:curated_memory_limits` and enforced on both read and write through `Pincer.Core.CuratedMemory`.
- Parallel tool fan-out is configurable with `:tool_max_concurrency`.
- Pluggable `Pincer.Ports.Sandbox` port with `Local`, `Docker` (`--cap-drop ALL`, `no-new-privileges`, `--network none`, `--user uid:gid`), and `SSH` adapters.
- Zero-infra embedded SQLite3 + FTS5 + WAL storage backend (`Pincer.Storage.Adapters.SQLite`), onboarding (`mix pincer.setup --storage sqlite`), and `Pincer.Core.Doctor` storage diagnostics.
- Closed-loop `Introspection.Kernel` → `Skills.Generator` / `Skills.Guard` → `Session.Server` skill promotion and prompt injection.
- Multi-backend `mix pincer.purge_indices` via `Pincer.Ports.Storage.purge_invalid_documents/1`.
- Postgres-free `sqlite-smoke` CI gate, strict posture fixture checks (`doctor --strict` and `security_audit --strict`), and opt-in real container Docker E2E suite (`--only docker`).
- Open-source governance files (`SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `CODE_OF_CONDUCT.md`).

### Fixed
- Delegated sub-agents fail fast when a privileged tool other than `dispatch_agent` needs approval instead of broadcasting to an unattended topic and waiting for the 600-second timeout.
- Approved `safe_shell` commands are re-validated against the static checks before execution, so approving a tool no longer bypasses the path and metacharacter guards.
- The local sandbox `:os` transport, SSH remote workspaces, and `browser` navigation now enforce the same guards (command allowlist, remote path validation, SSRF blocklist) as the rest of the tool surface.
- Changing the default model now edits only the `llm` section of `config.yaml` instead of regenerating the file and dropping unrelated sections; it also no longer re-reads `.env`.
- LINE, Feishu, and DingTalk HTTP calls now set connect/receive timeouts.
- Feishu, LINE, and DingTalk now honor the env var names configured in `config.yaml` (`app_id_env`, `token_env`, `secret_env`, `client_id_env`, `client_secret_env`) instead of hard-coded variable names.
- Feishu, LINE, and DingTalk sessions are resolved by the core session resolver, including DM binding and group-scoped session IDs.
- Tool approval decisions are recorded in the audit log, and a configured role without `:approve_tools` cannot approve privileged tools.
- Approval requests are delivered before the audit row is written, so a saturated database pool can no longer delay the prompt behind an audit insert.
- In-memory state (provider and auth-profile cooldowns, pairing codes, project state, memory budgets, model cache) survives the exit of the process that first used it, and the Blackboard no longer reuses message ids after a restart.
- Model lists are cached per provider configuration, so switching providers or reloading `config.yaml` no longer serves the previous list for up to an hour.

### Removed
- Unused modules that were only referenced by their own tests (`ModelRouter`, `ProjectBoard`, `ContractEngine`, `Capabilities`, `Session.CommandQueue`, `ReleaseValidation`, `Storage.Port`, `Core.SubAgent`) and the incomplete Matrix channel tree, which pointed at a non-existent session module.
- Manual debug scripts moved from `test/` to `scripts/manual/` so they no longer run as part of `mix test`.

### Security
- Replaced the vulnerable `earmark` wrapper with `earmark_parser` (the maintained AST parser Earmark already proxied), updated `db_connection` to 2.10.3, and removed the unused `tesla`/`hackney` clients, dropping the vulnerable `idna` transitive dependency. `mix deps.get` now resolves with no Hex vulnerability warnings.
- Centralized outbound URL validation in `Pincer.Utils.NetworkGuard`: rejects URL credentials, unsupported schemes, loopback/private/link-local/metadata/reserved IPv4 and IPv6 ranges, resolves all A/AAAA records, and pins `web_fetch` and attachment downloads to the validated address while preserving TLS SNI and the `Host` header. Redirects are revalidated and repinned; browser requests are checked by the Playwright sidecar.
- Capped `web_fetch` and attachment bodies with a streaming Req sink that halts downloads above the limit, and added connect timeouts; removed the invalid `max_body_length` Req option that raised at runtime.
- Removed unvalidated MCP `shell_server.py` and Node `mcp_sidecar` PoC; blocked MCP `run_command` execution in `Pincer.Adapters.NativeToolRegistry`.
- Hardened `SafeShell` to require approval for destructive/exec/file-writing `find` and `git log` flags.
- Enforced workspace path confinement (`WorkspaceGuard`) across media, channel actions, code skeleton, and archive extraction.
- Switched webhook token validation (`Pincer.Channels.Webhook`) to constant-time `:crypto.hash_equals/2` and defaulted `/health` Bandit bind to loopback `127.0.0.1`.
- Eliminated TLS hostname downgrade fallback in `Pincer.Adapters.Tools.Web` and dynamic `String.to_atom/1` creation in `Pincer.Infra.Config`, filesystem/MCP tools, and plugins.
- Removed precompiled `whatsapp_bridge` ELF binary and cleaned personal identifiers/local paths across source and docs.

## [0.1.0] - 2026-04-12

### Added
- Supervised OTP session architecture (`Pincer.Core.Session.Server`, `Pincer.Core.Executor`, Horde clustering, circuit breaker, retry/backoff policies).
- Modular Hex packages under `packages/*` covering `pincer_ports`, `pincer_shared`, 14 LLM provider adapters, and channel adapters (`CLI`, `Telegram`, `Discord`, `Slack`, `WhatsApp`, `LINE`, `Feishu`, `DingTalk`, `Webhook`).
- PostgreSQL + pgvector semantic memory, Archivist, MCP stdio/HTTP connectors, cron scheduler, and sub-agent orchestrator.
