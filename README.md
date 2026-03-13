# Pincer

> **Autonomous AI Agents on the BEAM**

Pincer is a sophisticated AI agent framework built on Elixir/OTP, emphasizing fault tolerance, security, and multi-agent orchestration via the Model Context Protocol (MCP) and a Blackboard pattern.

## 🚀 Quick Start

1. **Start the stack**:
   ```bash
   docker compose up --build -d
   ```

   This bootstraps onboarding if needed, waits for PostgreSQL, creates the database, runs migrations, and starts the server.

2. **Start chatting**:
   ```bash
   docker compose exec pincer-server mix pincer.chat
   ```

## 🗄️ Database

Pincer now targets `PostgreSQL + pgvector` directly.

- Default local credentials are `postgres/postgres`
- Default local database names are `pincer_dev`, `pincer_test`, and `pincer`
- Runtime overrides are supported via:
  - `PINCER_DB_HOST`
  - `PINCER_DB_PORT`
  - `PINCER_DB_USER`
  - `PINCER_DB_PASSWORD`
  - `PINCER_DB_NAME`
  - `PINCER_DB_POOL_SIZE`
  - `PINCER_DB_SSL`

## 📚 Documentation

All agentic instructions and project protocols have been moved to the `.local/` directory for cleaner workspace management.

- See `.local/GEMINI.md` for a comprehensive overview.
- See `.local/AGENTS.md` for the development protocol.
- Runtime persona, memory and bootstrap state now live under `workspaces/<agent_id>/.pincer/`.

## 🤖 Telegram Agent Mapping

One Telegram bot can now route different DM users to different root agents while keeping each agent isolated in its own workspace:

```yaml
channels:
  telegram:
    enabled: true
    adapter: "Pincer.Channels.Telegram"
    token_env: "TELEGRAM_BOT_TOKEN"
    agent_map:
      "123": "annie"
      "456": "lucie"
```

- DM `123` is routed to session/agent `annie`
- DM `456` is routed to session/agent `lucie`
- Their runtime state lives in `workspaces/annie/.pincer/` and `workspaces/lucie/.pincer/`
- If a DM is not present in `agent_map`, Pincer keeps the DM-scoped `session_id` but resolves the root agent via bindings or legacy fallback

## 🔐 Telegram Pairing Codes

Pairing can now be issued out-of-band for Telegram DMs:

```bash
mix pincer.agent pair annie
mix pincer.agent pair
```

- `mix pincer.agent pair annie` emits a code that binds the next Telegram DM user who runs `/pair <codigo>` to the explicit root agent `annie`
- `mix pincer.agent pair` emits a generic code; when redeemed, the Telegram DM is bound to a new dedicated root agent with an opaque 6-digit hexadecimal ID
- targeted pairing requires the workspace to exist first, so create it with `mix pincer.agent new annie` when needed
- static `agent_map` still has precedence over dynamic pairing bindings

## 🛠️ Mix Tasks

- `mix pincer.server [channels...]`
  Starts the persistent server node. Example: `mix pincer.server telegram`
- `mix pincer.server service [install|remove|start|stop|restart|status] [--system]`
  Manages the systemd service in user mode by default.
- `mix pincer.chat`
  Starts the CLI and tries to connect to the server first.
- `mix pincer.agent new <agent_id>`
  Creates or reuses `workspaces/<agent_id>/.pincer/` without copying legacy persona files from the repo root.
- `mix pincer.agent new`
  Creates a brand-new root agent with an opaque 6-digit hexadecimal `agent_id`.
- `mix pincer.agent pair [agent_id]`
  Emits a Telegram pairing code; with `agent_id` it targets an existing root agent, without it Pincer creates a new dedicated root agent with an opaque hexadecimal ID on redemption.
- `mix pincer.doctor [--strict] [--config path/to/config.yaml]`
  Runs operational diagnostics for config, tokens, and DM policy.
- `mix pincer.security_audit [--strict] [--config path/to/config.yaml]`
  Runs a security-focused audit for channels and gateway posture.
- `mix pincer.onboard [--non-interactive] [--yes] [--db-name ...] [--provider ...] [--model ...]`
  Bootstraps config plus the per-agent `.pincer` template scaffold. In the PostgreSQL setup, `--db-name` writes the database name into `config.yaml`.

## 🧪 Testing

```bash
docker compose up -d postgres
mix ecto.create
mix ecto.migrate
mix test --warnings-as-errors
```

---

<p align="center">
  <strong>Built with 🔨 in Elixir</strong><br>
  <sub>Because agents deserve better than Python threads.</sub>
</p>
