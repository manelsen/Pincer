# Container Hardening Guide

When running Pincer inside Docker (`docker-compose.yml`), `PINCER_SANDBOX_TRANSPORT` defaults to `os` because nested bubblewrap namespaces (`bwrap`) are blocked by Docker's default seccomp/AppArmor profiles. While `Sandbox.Local` scrubs daemon environment variables (`*_API_KEY`, `*_TOKEN`, `*_SECRET`) before invoking `sh -c` and enforces `WorkspaceGuard`, all OS subprocesses still share the container filesystem and mounts (`data/`, `sessions/`, `workspaces/`).

## Recommended profiles

### Single-operator container

Use the default `docker-compose.yml`, which injects `.env` variables only into runtime process memory without bind-mounting `.env` onto the container filesystem, mounts `config.yaml` read-only, drops Linux capabilities (`cap_drop: [ALL]`), and sets `no-new-privileges:true`.

### Untrusted or multi-user deployments

Layer `docker-compose.hardened.yml` over the base Compose file and keep untrusted tool execution outside the daemon container:

```bash
docker compose -f docker-compose.yml -f docker-compose.hardened.yml up -d
```

Checklist before enabling external channels:

1. Avoid combining external chat channels (`telegram`, `discord`, `slack`, `whatsapp`, `webhook`) with `PINCER_SANDBOX_TRANSPORT=os`.
2. Route shell execution to an isolated sandbox backend (`bwrap` on bare metal, SSH to a dedicated sandbox host, or hardened MCP sidecars) that has zero access to daemon API keys or shared user workspaces.
3. Verify the effective runtime posture:

```bash
mix pincer.security_audit --strict
```
