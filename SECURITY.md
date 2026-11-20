# Security Policy

## Supported Versions

Security updates are applied to the `master` branch and active `0.1.x` releases.

| Version | Supported |
|---|---|
| `master` / `0.1.x` | Yes |

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Instead, report vulnerabilities privately through GitHub Security Advisories:

- https://github.com/manelsen/Pincer/security/advisories/new

Include as much detail as possible: affected module or configuration, reproduction steps, impact assessment, and any suggested mitigation.

We aim to acknowledge reports within **72 hours** and provide an initial triage or fix timeline within **7 days**.

## Security Architecture Highlights

Pincer enforces defense-in-depth across host tool execution, networking, and extensible skills:

- **Workspace confinement (`Pincer.Core.WorkspaceGuard`)**: path canonicalization, `..` rejection, and symlink chain validation across filesystem, media, code inspection, and channel actions.
- **Command validation (`Pincer.Adapters.Tools.SafeShell`)**: tokenized command whitelist, shell operator/newline blocking, destructive `find` / `git log` flag rejection, and human approval gating (`{:approval_required, cmd}`).
- **Container & local sandboxes (`Pincer.Ports.Sandbox`)**: hardened Docker execution (`--cap-drop ALL`, `--security-opt no-new-privileges`, `--network none`, `noexec` `/tmp`, host UID mapping) and confined OS execution.
- **SSRF protection (`Pincer.Adapters.Tools.Web`)**: blocks loopback, link-local metadata endpoints, and private network ranges across initial requests and redirects without downgrading TLS failures.
- **Skill safety gate (`Pincer.Core.Skills.Guard`)**: fail-closed static validation blocking malicious promoted skills.
- **Posture diagnostics (`mix pincer.doctor --strict` and `mix pincer.security_audit --strict`)**: verifies gateway loopback bind, DM policies, workspace confinement, and storage health.
