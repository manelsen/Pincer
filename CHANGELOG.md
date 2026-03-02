# Changelog

All notable changes to Pincer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Project Manager Multi-Agent Wizard (SPR-079)**
  - Added `Pincer.Core.ProjectOrchestrator` with session-scoped project discovery wizard:
    - objective
    - project type (`software` vs `nao-software`)
    - scope/context
    - success criteria
  - Added adaptive multi-agent planning output (`Architect`, `Coder`, `Reviewer`) after discovery.
  - Added session kanban rendering from orchestrated project plans via `ProjectOrchestrator.board/2`.
  - Telegram and Discord now:
    - route `/project` to the interactive project manager wizard;
    - capture follow-up free text while project discovery is active;
    - route `/kanban` to session board when a plan exists, with fallback to global `TODO.md`.

- **Project Guidance View for `/project` (SPR-078)**
  - Added `view` support to `Pincer.Core.ProjectBoard.render/1` with:
    - `:kanban` (concise operational board)
    - `:project` (operational board + `DDD Checklist`, `TDD Checklist`, `Next Action`)
  - Telegram `/project` now renders `ProjectBoard.render(view: :project)`.
  - Discord `/project` (text + slash) now renders `ProjectBoard.render(view: :project)`.
  - `/kanban` behavior remains concise and unchanged.

- **Skills Sidecar Hardening Track (SPR-054..SPR-066)**
  - Added centralized fail-closed policy enforcement in `Pincer.Connectors.MCP.SkillsSidecarPolicy`.
  - Added sidecar execution audit telemetry and hard timeout behavior in `Pincer.Connectors.MCP.Manager`.
  - Added isolation and supply-chain guards for sidecar runtime:
    - required hardened docker baseline flags
    - required-flag effective value guard (last occurrence) for override-safe validation
    - digest-pinned image requirement
    - mount target allowlist (`/sandbox`, `/tmp`) + source confinement guards
    - sensitive env denylist for config `env` and docker args (`-e/--env`)
    - dangerous docker flag denylist expansion (`--privileged`, `--cap-add`, `--device`, `--pid=host`, `--ipc=host`, `--security-opt=*unconfined*`, `--mount`, `--env-file`)

- **CLI Interactive History (SPR-067)**
  - Added `Pincer.CLI.History` for persistent local CLI input history.
  - Added CLI commands:
    - `/history` (last 10 entries)
    - `/history N` (last N entries)
    - `/history clear` (clear persisted history)
  - `mix pincer.chat` now persists each sent user input line to history storage.

- **Universal Webhook Channel (SPR-068)**
  - Added receive-only channel `Pincer.Channels.Webhook` with generic `ingest/2` API.
  - Added routing features:
    - flexible text extraction from common webhook payload shapes
    - session resolution via explicit `session_id` or `source + sender_id`
    - event dedupe using `event_id`
  - Added fail-closed auth posture:
    - webhook channel now requires `token_env` to start
    - `ingest/2` requires valid token for accepted payloads
  - Added default webhook channel config stub in `config.yaml` (disabled by default).
  - Security audit now treats enabled `webhook` as token-protected surface.

- **Smart Sub-Agent Progress Notifications (SPR-069)**
  - Added `Pincer.Core.SubAgentProgress` deterministic policy for blackboard updates.
  - Added progress dedupe semantics:
    - start notification once per agent
    - tool notification only when tool changes
    - terminal (`FINISHED`/`FAILED`) notification once
  - Session heartbeat now emits deterministic `agent_status` updates from blackboard messages.
  - LLM-based blackboard evaluation now runs only for ambiguous/unclassified updates.
  - Telegram session now delivers `agent_status` as user-visible messages.

- **Telegram File Attachments (SPR-070)**
  - Added Telegram attachment ingestion in `UpdatesProvider` for:
    - `photo` payloads (images)
    - `document` payloads (`pdf`, image, `log`, `txt`)
  - Added `prepare_input_content/2` to build multimodal input payloads (`attachment_ref`) for `Session.Server`.
  - Added `Pincer.Core.Executor.resolve_attachment_url/2` to translate secure runtime URL schemes (`telegram://file/...`) into Telegram download URLs without persisting bot token in session history.

- **Skills Sidecar v2 Checksum + Audit Metadata (SPR-071)**
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy` now requires explicit artifact checksum declaration (`artifact_checksum`/`skill_artifact_checksum`) in `sha256:<64-hex>` format.
  - Sidecar policy now fails closed on missing or invalid artifact checksums.
  - `Pincer.Connectors.MCP.Manager.audit_sidecar_result/6` now propagates execution metadata (`skill_id`, `skill_version`, `artifact_checksum`) to sidecar telemetry events.

- **Dockerized Server Runtime (SPR-072)**
  - Added multi-stage `Dockerfile` for Pincer server runtime with non-root execution and runtime Mix/Hex cache.
  - Added `.dockerignore` to reduce build context and avoid shipping local runtime artifacts/secrets.
  - Added `docker-compose.yml` service (`pincer-server`) with persistent bind mounts for `db/`, `logs/`, `sessions/`, and `memory/`.
  - Added `infrastructure/docker/entrypoint.sh` to run `mix ecto.migrate` before starting `mix pincer.server`.
- **Pairing Persistence + Out-of-Band Approval (FIX-075)**
  - Added persistent pairing storage in `Pincer.Core.Pairing` using DETS (`sessions/pairing_store.dets`) with ETS bootstrap on runtime table recreation.
  - Added out-of-band pairing code emission for operator workflows:
    - structured pairing logs with channel/sender/code metadata
    - PubSub broadcast on `session:cli:admin` with pairing code payload

- **Core Retry/Transient Policy**
  - Added `Pincer.Core.RetryPolicy` as a centralized operational policy for:
    - `retryable?/1` request-level decisions
    - `transient?/1` warning-vs-error operational decisions
    - `retry_after_ms/3` and `parse_retry_after/2` normalization
- **Core Deterministic Failover Policy (v1)**
  - Added `Pincer.Core.LLM.FailoverPolicy` with deterministic actions:
    - `:retry_same`
    - `{:fallback_model, provider, model}`
    - `{:fallback_provider, provider, model}`
    - `:stop`
  - Added failover state summarization via `summarize_attempts/1`.
- **Core Provider Cooldown Store (v1)**
  - Added `Pincer.Core.LLM.CooldownStore` for cross-request provider cooldown memory.
  - Added cooldown operations:
    - `cooldown_provider/2`
    - `cooling_down?/1`
    - `available_providers/1`
    - `clear_provider/1`
- **Core Channel Interaction Policy (v1)**
  - Added `Pincer.Core.ChannelInteractionPolicy` to centralize callback/custom-ID building and parsing.
  - Enforces per-channel payload limits:
    - Telegram callback payloads up to 64 bytes
    - Discord custom IDs up to 100 bytes
  - Added strict parsing for:
    - `select_provider`
    - `select_model`
    - `back_to_providers`
    - `show_menu`
- **Onboarding Preflight + Merge Utilities (v1)**
  - Added `Pincer.Core.Onboard.preflight/1` with actionable issues (`id`, `message`, `hint`).
  - Added `Pincer.Core.Onboard.merge_config/2` for deep merge of defaults and existing config maps.
- **Onboarding Remote/Assisted Toolkit (v1)**
  - Added `Pincer.Core.Onboard.assisted_preflight/2` for environment readiness checklist (channel tokens, provider credentials, MCP commands).
  - Added `Pincer.Core.Onboard.remote_assisted_plan/2` for deterministic remote bootstrap command generation.
- **MCP HTTP SSE Support (v1)**
  - `Pincer.Connectors.MCP.Transports.HTTP` now parses `text/event-stream` bodies with incremental `data:` JSON-RPC events.
  - SSE `data: [DONE]` sentinel is ignored safely.
  - Added explicit SSE parse errors: `{:error, {:invalid_sse_data, ...}}`.
- **MCP HTTP Long-lived Stream Resilience (v1)**
  - Added reconnect policy to `Pincer.Connectors.MCP.Transports.HTTP` for transient SSE interruptions.
  - Added configurable reconnect controls:
    - `max_reconnect_attempts`
    - `initial_backoff_ms`
    - `max_backoff_ms`
    - `sleep_fn` (testable backoff hook)
  - Added heartbeat/comment filtering and cross-reconnect payload dedupe.
- **Skills Install Trust Boundary Hardening (v1)**
  - `Pincer.Core.Skills.install/2` now requires explicit opt-in (`allow_install: true`).
  - Source policy now enforces secure URI scheme defaults (`https`) and host validation.
  - Source allowlist now supports wildcard suffix rules (`*.trusted.example.com`).
- **Concurrent Resilience Test Coverage (SPR-047 / C05)**
  - Added Telegram flood test for malformed callback batches in `UpdatesProvider`.
  - Added Discord malformed interaction flood test for missing `id/token` envelopes.
  - Added LLM backoff test validating concurrent model changes with last-write-wins behavior.
- **SessionScope Streaming Consistency (SPR-048 / C17)**
  - Added dynamic session-topic rebinding support in Telegram/Discord session workers.
  - Added session-level tests for rebinding workers to `telegram_main`/`discord_main`.
- **Dynamic MCP `config.json` Loading (SPR-049)**
  - Added `Pincer.Connectors.MCP.ConfigLoader` to discover MCP servers from external JSON configs.
  - Supports both:
    - top-level `mcpServers` (Cursor/Claude Desktop style);
    - nested `mcp.servers` (Pincer-compatible variant).
  - Added deterministic merge helper where static project config overrides dynamic name collisions.

### Changed

- **Tool-Call Argument Normalization + Telegram Native-First Menu (SPR-073)**
  - `Pincer.Core.Executor` now tolerates non-string `tool_calls.function.arguments` payloads (map, empty, JSON string) without crashing execution loops.
  - Tool-call parsing now normalizes mixed key shapes (string/atom) and keeps malformed payloads fail-soft at tool-message level.
  - `Pincer.Channels.Telegram.menu_reply_markup/0` now defaults to native-first (`remove_keyboard: true`) to avoid duplicate menu affordances on mobile.
  - Telegram can still opt into legacy persistent keyboard via `channels.telegram.menu_keyboard: "persistent"`.
- **Pairing UX Copy (FIX-075)**
  - `Pincer.Core.AccessPolicy` no longer exposes pairing code in blocked DM responses.
  - Telegram/Discord `/pair` guidance now follows out-of-band operator flow (request code from operator instead of generating it in the blocked conversation).
- **Tool-Call History Type + Config Read Fail-Safe (FIX-074)**
  - `Pincer.Core.Executor` now enriches streamed `assistant.tool_calls` with `"type": "function"` when missing, preserving provider-compatible history across tool turns.
  - `Pincer.LLM.Client`, `Pincer.Core.LLM.CooldownStore`, and `Pincer.Core.AuthProfiles` now read list-shaped runtime config fail-safe (keyword and non-keyword lists) without `Keyword.get/3` crashes.
- **Retry and Logging Integration**
  - `Pincer.LLM.Client` now delegates retryability and `Retry-After` handling to `Pincer.Core.RetryPolicy`.
  - `Pincer.Session.Server` now uses centralized transient policy for executor failure log level.
  - `Pincer.Channels.Telegram.UpdatesProvider` now uses centralized transient policy for polling error log level.
- **Attachment Fallback Behavior**
  - `Pincer.Core.Executor` now converts `text/*` `attachment_ref` payloads into plain text when the active provider does not support native file inputs.
- **Failover Integration**
  - `Pincer.LLM.Client` now delegates terminal retryable failures to `FailoverPolicy.next_action/2`.
  - Client can now perform deterministic model/provider failover before terminal stop.
  - `Pincer.Core.LLM.FailoverPolicy` now ignores provider candidates currently in cooldown.
- **Cooldown-Aware Routing**
  - `Pincer.LLM.Client` now:
    - applies cooldown on transient terminal provider failures;
    - clears cooldown on successful provider usage;
    - bypasses default provider when it is cooling down and a healthy provider exists.
- **Channel Interaction Hardening**
  - `Pincer.Channels.Telegram` now filters oversized callback payloads when building inline model/provider menus.
  - `Pincer.Channels.Telegram` now validates callback action payload shape through core policy before model selection.
  - `Pincer.Channels.Discord` now safely handles malformed interactions without `data.custom_id`.
  - `Pincer.Channels.Discord` now filters oversized `custom_id` payloads in provider/model interaction buttons.
- **Onboarding Task Safety**
  - `mix pincer.onboard` now merges existing `config.yaml` with defaults before applying overrides.
  - `mix pincer.onboard` now validates option matrix so `--db-path`, `--provider` and `--model` require `config_yaml` capability when capabilities are explicitly scoped.
  - `mix pincer.onboard` now runs preflight before `apply_plan/2` and fails early with actionable hints.
  - `mix pincer.onboard` now supports remote-assisted mode (`--mode remote`) with `--remote-host`, `--remote-user`, and `--remote-path`.
  - Remote-assisted onboarding now prints expanded environment checklist and suggested SSH bootstrap steps without mutating local onboarding files.
- **MCP HTTP Transport Lifecycle**
  - `Pincer.Connectors.MCP.Transports.HTTP.close/1` now executes optional cleanup callback and remains failure-safe.
  - HTTP transport now retries transient stream interruptions with exponential backoff and preserves delivery idempotence across reconnect.
- **MCP Manager Server Resolution**
  - `Pincer.Connectors.MCP.Manager` now resolves server config through dynamic loader integration before booting clients.
  - Invalid/missing dynamic JSON files now degrade safely without crashing MCP startup.
- **Skills Installation Safety**
  - Skills sandbox root is now checked to reject symlink roots before installation.
  - Source validation now rejects URLs without host/scheme or non-allowed schemes, even when host is listed.
- **Interaction Envelope Hardening (Discord)**
  - `Pincer.Channels.Discord.Consumer` now validates interaction `id`/`token` before calling `create_interaction_response/3`.
  - Invalid envelopes are ignored with warning logs, preventing noisy API calls under malformed floods.
- **Hot-Swap Backoff Determinism**
  - `Pincer.LLM.Client` now drains queued `{:model_changed, provider, model}` events during retry backoff.
  - The effective swap now follows last-write-wins semantics before immediate retry.
- **Channel Session Worker Lifecycle**
  - `Pincer.Channels.Telegram.Session.ensure_started/2` and `Pincer.Channels.Discord.Session.ensure_started/2` now bind workers to the effective routed `session_id`.
  - Session supervisors now accept explicit `session_id` on worker bootstrap for deterministic PubSub topic binding.
  - Added `Pincer.PubSub.unsubscribe/1` to support safe session-topic rebinding.
- **Tool Surface Hardening (SPR-050 / Security)**
  - `Pincer.Tools.FileSystem` now enforces workspace confinement with existing-ancestor symlink resolution to block jail escape via symlink chains.
  - `Pincer.Tools.SafeShell` now requires approval for unsafe path-like arguments (absolute path, home expansion, traversal, null-byte) across path and generic whitelisted commands.
  - `Pincer.Tools.Web` now normalizes hostnames (`localhost.` -> `localhost`), performs safe IPv4/IPv6 private-range checks, and blocks DNS resolution to internal/private addresses.
- **Channel A11y Baseline Routing (SPR-051 / UX-A11y)**
  - `Pincer.Core.UX` now exposes `resolve_shortcut/1` to normalize keyboard-friendly command shortcuts (`menu`, `status`, `models`, `ping`) with and without `/`, while preserving `Menu`, `/help`, and `/commands`.
  - Telegram and Discord adapters now route validated plain-text shortcuts through the same command handlers used by slash commands.
  - Core UX copy now includes explicit route guidance for command usage with or without `/`, keeping hints short and actionable for screen-reader flows.

### Fixed

- **Discord Tool-Execution Crash Path**
  - Prevented `FunctionClauseError` / binary-concat crashes in executor when providers return tool-call arguments as decoded maps during online research/tool flows.
- **Telegram Tool-Continuation Failure Path (FIX-074)**
  - Prevented provider-side `400` errors (`Tool type cannot be empty`) by preserving tool call type in assistant history after streamed tool calls.
  - Prevented terminal-failure follow-up `FunctionClauseError` when cooldown/retry config is provided as malformed non-keyword list.
- **Test Stability**
  - Reduced flakiness in retry policy HTTP-date test by accounting for second-level precision in `Retry-After` formatting.
- **Interaction Resilience**
  - Prevented malformed `select_model` payloads (e.g. empty provider/model) from being accepted in Telegram callback flow.
- **Onboarding Config Preservation**
  - Prevented accidental loss of custom sections in existing `config.yaml` during non-interactive onboarding runs.
- **MCP Incremental Delivery**
  - Prevented streamable HTTP responses from being rejected as invalid plain response bodies when using SSE transport mode.
- **Skills Governance Gaps**
  - Prevented accidental skill installation without explicit install permission.
- **Concurrent Model-Swap Race**
  - Prevented stale model selection from winning when multiple model changes arrive during the same backoff window.
- **SessionScope Streaming Mismatch**
  - Prevented loss of `agent_partial`/`agent_response` delivery when DM routing used shared scope IDs (`telegram_main`/`discord_main`).
- **Web IPv6/SSRF Crash Path**
  - Prevented crashes when parsing IPv4-mapped IPv6 hosts (for example `::ffff:127.0.0.1`) by handling IPv4/IPv6 tuple shapes explicitly.
- **FileSystem Symlink Jail Escape**
  - Prevented read access outside workspace when user paths traverse symlinked ancestors that resolve outside the project root.
- **Docker Build/Runtime Compatibility**
  - Added missing `config/prod.exs` required by `MIX_ENV=prod` in container builds.
  - Updated `Pincer.Tools.WebVisibility` to avoid module-attribute regex injection incompatibility on Elixir 1.18 compilation.

### Removed

- **Legacy MCP Sidecar PoC (Node)**
  - Removed `mcp_sidecar/` from the repository to reduce attack surface and maintenance debt.
  - Removed ad-hoc sidecar test scripts:
    - `test/test_sidecar_mcp.exs`
    - `test/test_10_skills.exs`
  - Sidecar runtime remains a planned capability under hardened contract:
    - `docs/SPECS/SIDECAR_RUNTIME_HARDENED_V2.md`

## [0.1.0] - 2026-02-20

### Added

- **Core Agent System**
  - Unified Executor with ReAct-style reasoning loop
  - Loop detection (identical tool calls in last 6 iterations)
  - Recursion limit (max 15 iterations)
  - Human-in-the-loop approval workflow

- **MCP Integration**
  - Native Model Context Protocol support
  - Automatic tool discovery from MCP servers
  - Stdio transport implementation
  - JSON-RPC 2.0 client

- **Sub-Agents**
  - Blackboard pattern for inter-agent communication
  - SubAgent GenServer for background tasks
  - Orchestrator tool for dispatching

- **Tools**
  - `FileSystem` - File and directory operations
  - `SafeShell` - Shell commands with whitelist approval
  - `Web` - HTTP requests with Brave Search integration
  - `GitHub` - GitHub API integration
  - `Scheduler` - Delayed task scheduling
  - `GraphMemory` - Persistent knowledge graph (SQLite)
  - `Orchestrator` - Sub-agent dispatch
  - `BlackboardReader` - Read messages from Blackboard

- **Channels**
  - Telegram integration with long polling
  - CLI interactive mode
  - Factory pattern for channel creation

- **Storage**
  - SQLite adapter for message persistence
  - Graph adapter for knowledge graph (Node/Edge schema)
  - Port behaviour for storage abstraction

- **Infrastructure**
  - Cron scheduler with persistent jobs
  - PubSub event bus
  - Configuration management with layered sources
  - Token counter utility
  - Hot code reloader (development mode)

- **Documentation**
  - 100% module coverage with @moduledoc/@doc
  - ASCII architecture diagrams
  - @spec type specifications
  - Comprehensive README with examples
  - Quick start guide

### Security

- Dangerous shell commands require explicit approval
- Whitelist for safe shell commands
- No secrets in code or config files
- Environment variable based authentication

[0.1.0]: https://github.com/micelio/pincer/releases/tag/v0.1.0
