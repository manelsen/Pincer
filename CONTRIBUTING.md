# Contributing to Pincer

Follow this workflow and quality checklist before you open a pull request.

## Development setup

Pincer uses embedded SQLite3 (`exqlite`) only. You do not need PostgreSQL, Docker, or a migration command to run the framework or test suite.

```bash
git clone https://github.com/manelsen/Pincer.git && cd Pincer
mix deps.get
./scripts/build_sqlite_vec.sh   # Optional native sqlite-vec extension (falls back to cosine similarity)
mix pincer.setup --yes          # Initializes config and data/pincer.db
```

## Development protocol

1. **Write the spec first.** Document behavioral changes in [SPECS.md](SPECS.md) before editing code.
2. **Follow TDD (Red, Green, Refactor).** Add a failing test first, implement the minimal change to pass it, then clean up. Isolate temporary workspaces and stub external processes in unit tests instead of running commands against the repository root.
3. **Keep compilation and formatting clean.** `mix.exs` compiles with `warnings_as_errors: true`. Every new module and public function needs `@moduledoc` or `@doc`.
4. **Respect hexagonal boundaries.** The `boundary` compiler plugin checks layer dependencies at compile time:
   - `Pincer.Channels` and `Pincer.CLI` depend outward-to-inward on `PincerPorts`, `Pincer.Plugin`, `Pincer.Core`, and `Pincer.Utils`.
   - `Pincer.Adapters` depends on `Pincer.Core`, `Pincer.Ports`, `Pincer.Infra`, `Pincer.Utils`, and `PincerPorts`.
   - `Pincer.LLM` depends on `Pincer.Core`, `Pincer.Ports`, `Pincer.Utils`, and `PincerPorts`.
   - `Pincer.Core` depends only on `Pincer.Ports`, `Pincer.Infra`, and `Pincer.Utils`.
   - `Pincer.Ports` depends only on `PincerPorts`.
5. **Scope each PR to one issue.** Keep unrelated cleanups and version bumps in separate pull requests.

## Pre-PR checks

Run the full validation suite before pushing:

```bash
mix format --check-formatted
MIX_ENV=dev mix compile --warnings-as-errors
mix boundary.spec
mix qa                    # Format check, strict compile, and fast ExUnit run
mix sprint.check          # Same gate without --max-failures
```

Run standalone package checks and strict security posture checks when you change packages, config, or onboarding:

```bash
elixir scripts/check_packages.exs
OPENROUTER_API_KEY=ci-posture-check mix pincer.doctor --strict --config test/fixtures/ci_posture/config.yaml
OPENROUTER_API_KEY=ci-posture-check mix pincer.security_audit --strict --config test/fixtures/ci_posture/config.yaml
```

To run the gated WhatsApp Go bridge tests (Go 1.21+ required):

```bash
PINCER_WHATSAPP=1 mix test --warnings-as-errors \
  test/pincer/channels/whatsapp_test.exs \
  test/pincer/channels/whatsapp_session_test.exs \
  test/pincer/channels/whatsapp_bridge_test.exs
```

Read [AGENTS.md](AGENTS.md) for detailed subsystem conventions and [SECURITY.md](SECURITY.md) for vulnerability disclosure rules.
