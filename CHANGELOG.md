# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Pluggable `Pincer.Ports.Sandbox` port with `Local`, `Docker` (`--cap-drop ALL`, `no-new-privileges`, `--network none`, `--user uid:gid`), and `SSH` adapters.
- Zero-infra embedded SQLite3 + FTS5 + WAL storage backend (`Pincer.Storage.Adapters.SQLite`), onboarding (`mix pincer.setup --storage sqlite`), and `Pincer.Core.Doctor` storage diagnostics.
- Closed-loop `Introspection.Kernel` → `Skills.Generator` / `Skills.Guard` → `Session.Server` skill promotion and prompt injection.
- Multi-backend `mix pincer.purge_indices` via `Pincer.Ports.Storage.purge_invalid_documents/1`.
- Postgres-free `sqlite-smoke` CI gate, strict posture fixture checks (`doctor --strict` and `security_audit --strict`), and opt-in real container Docker E2E suite (`--only docker`).
- Open-source governance files (`SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `CODE_OF_CONDUCT.md`).

### Security
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
