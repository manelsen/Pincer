# GEMINI.md - Pincer Operational Mandates

> **Project Overview:** Pincer is an autonomous AI agent framework built on Elixir/OTP, leveraging the BEAM for fault tolerance, security, and complex multi-agent orchestration via the Model Context Protocol (MCP) and a Blackboard pattern.

---

## 📜 Core Mandates (Lei Marcial)

As defined in `AGENTS.md` and `SPECS.md`, all development must follow these rules:

1.  **Doc-First + TDD:** NO code is written without a prior specification (in `SPECS.md` or a task plan).
    - **RED:** Write a failing test in `test/xxx_test.exs`.
    - **GREEN:** Implement minimum code to pass.
    - **REFACTOR:** Improve code while keeping tests green.
2.  **Boundary Enforcement:** Adhere to the hexagonal architecture. Boundaries are defined in `mix.exs` and `lib/pincer/`.
3.  **Security First:** Use `Pincer.Tools.SafeShell` and `Pincer.Core.WorkspaceGuard` for all filesystem/shell operations. Comply with `Pincer.Core.SecurityAudit` standards.
4.  **No Reversions:** Do not revert changes unless they cause errors or the user explicitly asks.
5.  **Warnings as Errors:** Every commit must compile without warnings (`mix compile --warnings-as-errors`).

---

## 🛠️ Technical Stack

-   **Backend:** Elixir 1.14+ (OTP, Phoenix PubSub for messaging).
-   **Native:** Rust (via `rustler` for `pincer_lancedb`).
-   **Sidecar:** Node.js/TypeScript (for MCP tools).
-   **Storage:** SQLite (Ecto) for persistence, LanceDB for vector/graph memory.
-   **Communication:** Telegram (ExGram), Discord (Nostrum), Webhooks, CLI.

---

## 🚀 Key Workflows

### 1. Daily Initialization
-   Read `SOUL.md` (Identity).
-   Read `USER.md` (User Context).
-   Check `workspaces/<agent_id>/.pincer/` for recent sessions and memories.
-   Run `mix pincer.doctor` to verify environment health.

### 2. Implementation Loop
-   Update `SPECS.md` with the new increment.
-   Create a failing test.
-   Implement logic in the correct boundary (e.g., `Pincer.Core`, `Pincer.Connectors`).
-   Verify with `mix qa`.

---

## 📂 Directory Structure

-   `lib/pincer/`: Core boundaries (Core, Session, LLM, MCP, Tools, etc.).
-   `workspaces/`: Per-agent cognitive state (`.pincer/` folder contains Persona, Memory, and Session Logs).
-   `mcp_sidecar/`: Hardened Node.js environment for MCP tools.
-   `infrastructure/`: Deployment assets (Docker, systemd).
-   `test/`: Unit, integration, and contract tests.

---

## 📋 Essential Commands

| Command | Purpose |
| :--- | :--- |
| `mix pincer.chat` | Starts the interactive CLI agent. |
| `mix pincer.server` | Starts the persistent node (Telegram/Discord). |
| `mix pincer.onboard` | Bootstraps config and scaffolds agent workspaces. |
| `mix pincer.doctor` | Operational diagnostics for config/tokens. |
| `mix pincer.security_audit` | Security-focused audit for gateway posture. |
| `mix qa` | Comprehensive Quality Assurance (Format + Compile + Test). |
| `mix test` | Standard test execution. |

---

## 🧠 Memory & Context

-   **Short-term:** `workspaces/<id>/.pincer/HISTORY.md` (structured session log).
-   **Long-term:** `workspaces/<id>/.pincer/MEMORY.md` (curated insights).
-   **Identity:** `workspaces/<id>/.pincer/IDENTITY.md` and `SOUL.md`.

---
*Built with Elixir/OTP - Because agents deserve better than Python threads.*
