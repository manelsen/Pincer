defmodule Pincer.Core.Routing do
  @moduledoc """
  Documentation module describing the Pincer message routing architecture.

  This module contains no runtime code — its purpose is to serve as an
  authoritative reference for developers navigating the message flow.

  ## Message Routing Pipeline

  ```
  Channel Input
      │
      ▼
  Channel Adapter (lib/pincer/channels/*.ex)
      │  Normalizes raw channel events to %ChannelMessage{}
      │  Implementations: Telegram, Discord, Slack, WhatsApp, CLI, Webhook,
      │                   DingTalk, Feishu, LINE, Matrix
      │
      ▼
  Session.Server (lib/pincer/core/session/server.ex)
      │  GenServer per user session; supervised by Session.Supervisor
      │  Maintains conversation state and applies access/channel policies
      │
      ├──► Project Router (lib/pincer/core/project_router.ex)
      │        Handles slash commands: /reset, /new, /status,
      │        /learn, /project start|approve|pause|resume|stop|modify
      │        Returns {:ok, reply} | {:handled, reply} | :error
      │
      └──► Executor (lib/pincer/core/executor.ex)
               Runs the agentic loop: LLM → tool calls → LLM
               Max recursion depth: 15
               Resolves tools from native registry + MCP servers
  ```

  ## Outbound Message Flow

  ```
  Executor / ProjectRouter
      │
      ▼
  Dispatcher (lib/pincer/core/dispatcher.ex)
      │  Single outbound delivery point; delegates to Messaging port
      │
      ▼
  Pincer.Ports.Messaging
      │  Port contract decoupling delivery from channel implementation
      │
      ▼
  Channel Adapter (sends reply back to user)
  ```

  ## Routing Decision Matrix

  | Input type              | Handler              |
  |-------------------------|----------------------|
  | `/reset`, `/new`        | ProjectRouter        |
  | `/status`               | ProjectRouter        |
  | `/learn <text>`         | ProjectRouter        |
  | `/project <subcommand>` | ProjectRouter        |
  | Regular text            | Executor             |
  | Tool approval response  | Session.Server       |
  | Hook event              | HookDispatcher       |

  ## Adding a New Channel

  1. Implement `Pincer.Ports.Channel` behaviour in `lib/pincer/channels/<name>.ex`.
  2. Register it in `config.yaml` under `channels:`.
  3. The channel supervisor (`Pincer.Channels.Supervisor`) starts it automatically.

  ## Adding a New Slash Command

  1. Add a parse clause to `Pincer.Core.ProjectRouter.parse/1` matching the command string.
  2. Add a `handle_command/3` clause for the new command atom.
  3. Commands must return `{:ok, reply}` or `{:handled, reply}` on success,
     or `{:error, reason}` on failure.

  ## See Also

  - `Pincer.Core.Dispatcher` — outbound message delivery
  - `Pincer.Core.ProjectRouter` — slash command parsing and dispatch
  - `Pincer.Core.Executor` — agentic reasoning loop
  - `Pincer.Core.Session.Server` — per-user session state
  - `Pincer.Ports.Channel` — channel adapter behaviour contract
  - `Pincer.Ports.Messaging` — outbound messaging port
  """
end
