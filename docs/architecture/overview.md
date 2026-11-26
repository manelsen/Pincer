# Technical Architecture Reference (`0.2.0`)

This reference expands the high-level diagrams in [README.md](../../README.md) with module-level Mermaid graphs derived from `lib/pincer/application.ex`, layer `use Boundary` declarations, and the `Core.Executor` turn loop.

For historical boundary context predating `0.2.0`, see [Architecture & Boundaries Report (2026-03-13)](2026-03-13-architecture-boundaries-report.md).

---

## End-to-end runtime pipeline

Top-down request flow from inbound messaging channels to session execution, guarded tools, LLMs, and post-turn consolidation:

```mermaid
flowchart TD
  subgraph Ingress["1. Ingress & Session Routing"]
    CH["Channel Packages (9 Adapters)"] --> SH["Pincer.Channels.Shared<br/>(Inbound, SessionBridge, ProjectBridge, Pairing)"]
    SH --> SS["Pincer.Core.Session.Server<br/>(InputBuffer, CommandDispatcher, TaskCoordinator)"]
  end

  subgraph Core["2. Supervised Turn Execution"]
    SS --> EX["Pincer.Core.Executor<br/>(PromptAssembly, MemoryRecall, ToolRunner)"]
    EX -. "streaming tokens" .-> SS
  end

  subgraph Capabilities["3. Ports, Providers & Post-Turn Consolidation"]
    EX --> LLM["PincerPorts.LLM<br/>(Failover, RetryEngine, 14 Providers)"]
    EX --> TR["Pincer.Ports.ToolRegistry<br/>(19 Native Tools & MCP)"]
    TR --> SB["Pincer.Ports.Sandbox<br/>(Local, bwrap, Docker, SSH)"]
    TR --> TTS["Pincer.Ports.TTS<br/>(Pincer.LLM.TTS)"]
    EX --> AR["Orchestration.Archivist & Introspection.Kernel"]
    AR --> DB["Pincer.Infra.SQLite<br/>(FTS5, Graph & sqlite-vec)"]
  end
```

---

## Compile-time `Boundary` `0.12` dependency map

Every layer declares explicit `use Boundary` `deps` and `exports`, enforced during compilation with `elixirc_options: [warnings_as_errors: true]`:

```mermaid
flowchart TD
  APP["Pincer.Application"] --> CH["Pincer.Channels"]
  APP --> AD["Pincer.Adapters (strict)"]
  APP --> CO["Pincer.Core"]
  APP --> IN["Pincer.Infra"]
  APP --> TE["Pincer.Telemetry"]
  APP --> UT["Pincer.Utils"]

  CLI["Pincer.CLI"] --> PL["Pincer.Plugin"]
  CLI --> CO
  CLI --> UT

  CH --> IN
  CH --> PL
  CH --> PP["PincerPorts (packages/pincer_ports)"]

  AD --> CO
  AD --> PO["Pincer.Ports (strict)"]
  AD --> IN
  AD --> UT
  AD --> PP

  LLM["Pincer.LLM"] --> CO
  LLM --> PO
  LLM --> UT

  CO --> PO
  CO --> IN
  CO --> UT

  PO --> PP
```

Inside `Pincer.Core`, 9 internal slices enforce inbound and outbound checks via `CoreSubBoundariesTest`: `Session`, `Project`, `Executor`, `Memory`, `Orchestration`, `Introspection`, `Skills`, `LLM`, and `Graph`. `Pincer.Ports` depends exclusively on `PincerPorts`, never on `Pincer.Infra`.

---

## Agentic turn and closed-loop skill promotion

Detailed interaction between `Session.Server`, `Core.Executor`, recall storage, tool safety guards, and fail-closed self-reflection:

```mermaid
sequenceDiagram
  actor User
  participant Channel as Channel Adapter
  participant Session as Session.Server
  participant Executor as Core.Executor
  participant Memory as MemoryRecall & SQLite
  participant LLM as LLM.Client & Provider
  participant Tools as ToolRunner & Sandbox
  participant Kernel as Introspection.Kernel

  User->>Channel: Send message
  Channel->>Session: Inbound route / SessionBridge
  Session->>Executor: Run turn in supervised Task
  Executor->>Memory: Recall HISTORY, MEMORY, FTS5 graph, vec0
  Memory-->>Executor: Sanitized context
  loop Up to max recursion depth 100
    Executor->>LLM: Stream chat completion with failover
    LLM-->>Executor: Tokens or tool calls
    opt Tool calls requested
      Executor->>Tools: WorkspaceGuard / RBAC / Sandbox check
      Tools-->>Executor: Bounded tool outputs
    end
  end
  Executor-->>Channel: Final response via PubSub
  Executor->>Kernel: Archivist consolidation and lesson capture
  opt Lesson promoted to SKILL.md
    Kernel->>Kernel: Skills.Generator then fail-closed Skills.Guard
    Kernel-->>Session: Broadcast {:kernel_skills_updated, skill}
  end
```

---

## OTP supervision tree

`Pincer.Application` boots a `:one_for_one` supervision tree (`lib/pincer/application.ex`) ordered from durable state and clustering foundations up to ingress supervisors:

```mermaid
flowchart TD
  SUP["Pincer.Supervisor (one_for_one)"] --> HEIR["Pincer.Utils.ETSTableHeir"]
  SUP --> CLUS["Cluster.Supervisor & NodeObserver"]
  SUP --> OBS["PromEx, PubSub, Memory & Conversation Observability"]
  SUP --> SQL["Pincer.Infra.SQLite & Finch Pool"]
  SUP --> HB["Pincer.Core.Heartbeat & Task Supervisors"]
  SUP --> MCP["Pincer.MCP.Supervisor & MCP.Manager"]
  SUP --> KRN["Introspection.Kernel.Supervisor & Kernel.Registry"]
  SUP --> SES["Session.Registry, HordeSupervisor & Session.Supervisor"]
  SUP --> PRJ["Project.Registry, HordeSupervisor, Supervisor & Recovery"]
  SUP --> GUARD["CircuitBreaker, RateLimiter, Pairing.Store & HookDispatcher"]
  SUP --> SCHED["Cron.Scheduler, TimerServer & Channels.Supervisor"]
  SUP --> HTTP["Bandit HTTP (/health)"]
```
