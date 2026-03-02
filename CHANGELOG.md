# Changelog

All notable changes to Pincer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
- **MCP HTTP SSE Support (v1)**
  - `Pincer.Connectors.MCP.Transports.HTTP` now parses `text/event-stream` bodies with incremental `data:` JSON-RPC events.
  - SSE `data: [DONE]` sentinel is ignored safely.
  - Added explicit SSE parse errors: `{:error, {:invalid_sse_data, ...}}`.
- **Skills Install Trust Boundary Hardening (v1)**
  - `Pincer.Core.Skills.install/2` now requires explicit opt-in (`allow_install: true`).
  - Source policy now enforces secure URI scheme defaults (`https`) and host validation.
  - Source allowlist now supports wildcard suffix rules (`*.trusted.example.com`).

### Changed

- **Retry and Logging Integration**
  - `Pincer.LLM.Client` now delegates retryability and `Retry-After` handling to `Pincer.Core.RetryPolicy`.
  - `Pincer.Session.Server` now uses centralized transient policy for executor failure log level.
  - `Pincer.Channels.Telegram.UpdatesProvider` now uses centralized transient policy for polling error log level.
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
- **MCP HTTP Transport Lifecycle**
  - `Pincer.Connectors.MCP.Transports.HTTP.close/1` now executes optional cleanup callback and remains failure-safe.
- **Skills Installation Safety**
  - Skills sandbox root is now checked to reject symlink roots before installation.
  - Source validation now rejects URLs without host/scheme or non-allowed schemes, even when host is listed.

### Fixed

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
