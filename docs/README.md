# Pincer Documentation

Browse guides, architecture notes, and subsystem specs for Pincer `0.2.0`.

## Start here

- [Project Overview & Quickstart](../README.md): Architecture diagrams, Docker and local setup, channels, providers, tools, and Mix tasks.
- [System Specifications](../SPECS.md): Provider environment matrix, failover policy, session lifecycle, heartbeat, skills security, and embeddings.
- [Changelog](../CHANGELOG.md): Release notes for `0.2.0` and earlier versions.

## Operations & Setup

- [Embedded sqlite-vec Setup](operations/sqlite-vec.md): Optional native vector extension build (`vec0.so` / `vec0.dylib`) and in-process cosine fallback.
- [Bubblewrap Sandbox (Linux)](operations/bubblewrap-sandbox.md): Rootless namespace isolation with `bwrap` and `prlimit`.
- [Opencode Zen Setup](OPENCODE_ZEN_SETUP.md): Configure `opencode_zen` and `openrouter` in `config.yaml` and `.env`.

## Architecture & Quality

- [Technical Architecture Reference](architecture/overview.md): Module-level Mermaid runtime pipeline, compile-time `Boundary 0.12` graph, turn sequence diagram, and OTP supervision tree.
- [Code Quality & SRP Audit](AUDIT-code-quality.md): Verified repository inventory, completed refactorings, test metrics, and remaining backlog items.
- [Architecture & Boundaries Report (2026-03-13)](architecture/2026-03-13-architecture-boundaries-report.md): Historical boundary diagnosis before the `0.2.0` compile-time `Boundary` mesh.
- [Agent Guide](../AGENTS.md): Authoritative contributor conventions, layer rules, and security invariants.

## Subsystem Specifications

- [Interactive CLI (`pincer.chat`)](SPECS/CLI_INTERACTIVE.md): REPL commands (`/status`, `/history`, `/clear`, `/quit`) and `{:cli_output, text}` protocol.
- [Hardened Sidecar Runtime v2](SPECS/SIDECAR_RUNTIME_HARDENED_V2.md): Sandboxed container sidecar execution specification.

## Governance

- [Contributing Guide](../CONTRIBUTING.md): Doc-First TDD workflow, hexagonal layer rules, and pre-PR checks.
- [Security Policy](../SECURITY.md): Coordinated vulnerability disclosure and supported versions.
- [Code of Conduct](../CODE_OF_CONDUCT.md): Community standards.
