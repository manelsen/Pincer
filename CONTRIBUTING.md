# Contributing to Pincer

Thank you for helping improve Pincer. Follow the workflow and quality standards below so changes merge smoothly.

## Development Setup

Pincer uses embedded SQLite only (zero external services). No PostgreSQL, Docker, or
migration step is required to develop or test.

```bash
git clone https://github.com/manelsen/Pincer.git && cd Pincer
mix deps.get
./scripts/build_sqlite_vec.sh   # optional: native sqlite-vec; search falls back to cosine
mix pincer.setup --yes          # initializes data/pincer.db
```

## Development Protocol (Mandatory)

1. **Doc-First**: document behavioral changes in `SPECS.md` before modifying code.
2. **TDD (Red → Green → Refactor)**: add or update a failing test first, implement the minimal change, then refactor. Never execute destructive shell/filesystem tests against real project roots; always isolate temporary workspaces and stub external runners in unit tests.
3. **Strict Compilation & Formatting**: warnings fail compilation (`warnings_as_errors: true`).
4. **Hexagonal Boundaries**: respect compile-time dependency rules declared via `use Boundary` (`Channels` / `Adapters` → `Core` → `Ports` → `Infra` / `Utils`). Never add cross-layer cycles.
5. **1 Issue = 1 PR**: keep each pull request scoped to a single issue or coherent concern.

## Quality Checks Before Opening a PR

```bash
mix format --check-formatted
MIX_ENV=dev mix compile --warnings-as-errors
mix qa                    # fast full-suite gate (SQLite, in-memory; no external DB)
mix sprint.check          # full test run without max-failures cap

# Optional sqlite-vec build for native vector search
./scripts/build_sqlite_vec.sh

# WhatsApp sidecar tests (requires Go 1.21+)
PINCER_WHATSAPP=1 mix test \
  test/pincer/channels/whatsapp_test.exs \
  test/pincer/channels/whatsapp_session_test.exs \
  test/pincer/channels/whatsapp_bridge_test.exs
```

Please see [AGENTS.md](AGENTS.md) for deeper architecture conventions and [SECURITY.md](SECURITY.md) for responsible disclosure.
