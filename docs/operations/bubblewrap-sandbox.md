# Bubblewrap sandbox (Linux)

Pincer can run local commands through [bubblewrap](https://github.com/containers/bubblewrap)
instead of the host shell. The transport keeps `SafeShell` and
`WorkspaceGuard` in front of every command; bwrap adds kernel-enforced mount,
PID, IPC, UTS, and network isolation. It is **Linux only** and **fail-closed**:
if the boot probe fails, Pincer refuses to start instead of silently running
commands on the host.

## 1. Install the binaries

```bash
sudo apt-get update
sudo apt-get install -y bubblewrap util-linux
```

`util-linux` provides `prlimit`, which applies the CPU, memory, PID, and
open-file limits.

## 2. Allow unprivileged user namespaces

Check the host policy:

```bash
sysctl kernel.apparmor_restrict_unprivileged_userns
```

- `0` (or the key is absent): nothing else to do.
- `1`: Ubuntu 24.04+ restricts unprivileged user namespaces. Install the
  AppArmor profile shipped in this repository and enforce it:

```bash
sudo install -m 0644 \
  infrastructure/apparmor/bwrap-userns-restrict \
  /etc/apparmor.d/bwrap-userns-restrict
sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict
sudo aa-enforce bwrap
```

The profile matches `/usr/bin/bwrap`. If your binary lives elsewhere, adjust
the `profile bwrap /usr/bin/bwrap` line before loading it.

Verify that bwrap can create the namespaces Pincer needs:

```bash
bwrap --unshare-all --die-with-parent --clearenv \
  --ro-bind /usr /usr --ro-bind /bin /bin \
  --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
  --proc /proc --dev /dev -- /bin/true
```

Exit status `0` means the probe will succeed. On distributions without
`/lib64`, omit that bind.

## 3. Configure Pincer

```yaml
sandbox:
  adapter: "local"
  local:
    transport: "bwrap"
    bwrap:
      network: "none"    # none | host
      limits:
        memory_mb: 1024
        cpu_seconds: 120
        pids: 4096
        open_files: 1024
```

- A supplied `limits` map replaces the defaults; `0`/absent disables one limit
  and `limits: :disabled` skips `prlimit` entirely.
- `network: "host"` uses `--share-net` and binds the host resolver/CA files.
- `PINCER_BWRAP_BINARY` and `PINCER_PRLIMIT_BINARY` override executable paths.
- `PINCER_SANDBOX_TRANSPORT=os|tool_registry|bwrap` overrides the YAML
  transport (invalid values are ignored with a warning).

## 4. Verify the boot path

The startup guard probes bwrap and `prlimit` before the supervision tree starts:

```bash
mix pincer.server
```

A failure aborts boot with `Sandbox indisponível: ...`. To prove fail-closed
behavior explicitly:

```bash
PINCER_BWRAP_BINARY=/nonexistent/bwrap mix pincer.server
# ❌ Sandbox indisponível: :bwrap_missing
```

To check the transport at runtime:

```bash
mix run -e '
  IO.inspect(Pincer.Ports.Sandbox.run("pwd",
    workspace_path: File.cwd!(), cwd: File.cwd!()))
'
```

The result must carry `metadata: %{transport: :bwrap}` and print `/workspace`.

## 5. Containers are different

Installing `bubblewrap` in the image is not enough: Docker's default AppArmor
and seccomp profiles block the nested user namespace bwrap needs. The
`docker-compose.yml` therefore pins the container to the OS transport:

```yaml
environment:
  PINCER_SANDBOX_TRANSPORT: os
```

Do not try to make the container work by adding `--privileged`; that gives away
the isolation the sandbox exists to provide. Use the bwrap transport for
bare-metal runs and the OS or Docker sandbox backend inside containers.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `bwrap: No permissions to create new namespace` | unprivileged user namespaces denied | install and enforce the AppArmor profile; check the sysctl |
| `{:error, {:prlimit_unavailable, nil}}` | `prlimit` not installed | install `util-linux` or set `PINCER_PRLIMIT_BINARY` |
| `{:error, :bwrap_missing}` | bwrap not installed / wrong path | install `bubblewrap` or set `PINCER_BWRAP_BINARY` |
| `{:error, {:probe_failed, code, output}}` | probe ran but failed | run the verification command from step 2 and read the output |
| Container restarts with `Sandbox indisponível` | bwrap nested in Docker | keep `PINCER_SANDBOX_TRANSPORT=os` in the container |

## Tests

The real-host integration suite is tagged `:bwrap` and excluded from normal
runs (it needs the host prerequisites above):

```bash
mix test test/pincer/adapters/sandbox/bwrap_integration_test.exs --include bwrap
```

Unit tests for the argument builder and `Local` routing run without bwrap:

```bash
mix test test/pincer/adapters/sandbox/ test/pincer/core/startup_guard_test.exs
```
