# Objective
Refactor the Pincer codebase to enforce a strict, opinionated Hexagonal Architecture (Ports and Adapters). The goal is to completely decouple the Core domain from all external concerns (Channels, LLM Providers, Storage, Tools). We will establish "macabre sirens" (strict compile-time boundary checks) to catastrophically fail the build if any module attempts to bypass these boundaries.

# Key Files & Context
- **Current Violations:** `lib/pincer/core/dispatcher.ex` explicitly aliases `Pincer.Channels.Telegram` and `Pincer.Channels.CLI`. This is a direct violation where the Core knows about specific delivery mechanisms (Adapters).
- **Domain Core (`lib/pincer/core/`, `lib/pincer/project/`, `lib/pincer/session/`):** Contains business logic but currently leaks adapter knowledge.
- **Ports (`lib/pincer/core/ports/`):** Needs to be expanded to cover all outbound side-effects (Messaging, LLM, Storage).
- **Adapters (`lib/pincer/channels/`, `lib/pincer/llm/providers/`, `lib/pincer/storage/adapters/`):** Must depend on the Core, never the reverse.

# Implementation Steps

## Phase 1: Establish Strict Ports (Behaviours)
1.  **Messaging Port:** Define `Pincer.Core.Ports.Channel` behaviour. The Core will only know how to send a generic `Pincer.Core.Structs.Message` to a port, not how a specific channel delivers it.
2.  **LLM Port:** Solidify `Pincer.Core.Ports.LLM` to ensure the core only deals with generic completion requests and responses, completely ignorant of provider specifics (OpenAI, Anthropic, etc.).
3.  **Storage Port:** Review and strictly enforce `Pincer.Storage.Port` across the session and project states.

## Phase 2: Invert Dependencies (Decoupling)
1.  **Refactor `Pincer.Core.Dispatcher`:** Remove all `alias Pincer.Channels.*`. The Dispatcher should either use `Pincer.Infra.PubSub` to broadcast outbound messages (which channels subscribe to) or use a dynamic registry of connected channels.
2.  **Anti-Corruption Layer (ACL):** Introduce `Pincer.Core.Structs.IncomingMessage`. Channels (Telegram, Discord, WhatsApp) must map their specific payloads into this generic struct *before* passing it to the `ProjectRouter` or `Session.Server`. The Core must never see a Telegram-specific map.

## Phase 3: The "Macabre Sirens" (Boundary Enforcement)
1.  **Boundary Tooling:** Integrate the `boundary` library (or configure strict `mix xref` checks in a custom compilation task) to define rules:
    *   `Pincer.Core` is allowed to depend on nothing outside itself (except standard libraries).
    *   `Pincer.Channels` is allowed to depend on `Pincer.Core`.
    *   `Pincer.LLM` is allowed to depend on `Pincer.Core`.
2.  **Compilation Hook:** Add a custom compiler step in `mix.exs` that breaks the build (`exit({:shutdown, 1})`) and prints a loud, aggressive warning if a dependency cycle or boundary violation is detected.

## Phase 4: Adapter Registration
1.  Instead of the Core knowing which channels are active, the Application boot sequence will start the Adapters, and the Adapters will register themselves to the Core's PubSub or Registry as listeners for specific session IDs.

# Verification & Testing
1.  **Boundary Check:** Run the compiler. The build must succeed. Then, intentionally add `alias Pincer.Channels.Telegram` inside a Core file and verify that the "macabre sirens" trigger and the build fails catastrophically.
2.  **Regression:** Run `mix test` to ensure the decoupling hasn't broken session flows.
3.  **Manual Test:** Start the server and verify that sending a message via Telegram still routes through the ACL, is processed by the Core, and is dispatched back through the generic Port to the Telegram Adapter.