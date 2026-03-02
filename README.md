# Pincer

> **Autonomous AI Agents on the BEAM**

[![Hex.pm](https://img.shields.io/hexpm/v/pincer.svg)](https://hex.pm/packages/pincer)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/pincer)
[![License](https://img.shields.io/github/license/micelio/pincer.svg)](LICENSE)

Pincer is an AI agent framework that doesn't apologize for being different. While others reinvent actor models in Python, Pincer leans into what the BEAM does best: **supervision, concurrency, and fault tolerance**.

```
┌─────────────────────────────────────────────────────────────────┐
│                         THE PINCER WAY                          │
│                                                                 │
│   Most frameworks:  LLM → orchestrate → hope it works          │
│   Pincer:           OTP → supervise → LLM reasons → BEAM heals │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Why Pincer?

### 1. Agents That Don't Die

```elixir
# Your agent crashes? No problem. OTP restarts it.
# Process runs for months? Normal. That's the BEAM.
# Hot code reload? Built-in. Update without downtime.
```

### 2. MCP-First Architecture

```elixir
# Connect to any Model Context Protocol server
config :pincer, mcp: [
  servers: [
    filesystem: %{command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"]},
    github: %{command: "npx", args: ["-y", "@modelcontextprotocol/server-github"]}
  ]
]

# Tools are discovered automatically. No manual registration.
```

### 3. Sub-Agents via Blackboard Pattern

```elixir
# Dispatch autonomous sub-agents for parallel work
Pincer.Tools.Orchestrator.execute(%{
  "goal" => "Monitor the stock market and alert on anomalies"
})

# They communicate through a shared Blackboard—no message-passing spaghetti
```

### 4. Human-in-the-Loop by Default

```elixir
# Dangerous operations require explicit approval
# SafeShell has a whitelist; everything else asks permission
def execute(%{"command" => cmd}) do
  if safe?(cmd), do: run(cmd), else: request_approval(cmd)
end
```

---

## Architecture

```
                    ┌────────────────────────────────┐
                    │           CHANNELS             │
                    │  Telegram │ CLI │ WhatsApp... │
                    └───────────────┬────────────────┘
                                    │
                    ┌───────────────▼────────────────┐
                    │      SESSION SUPERVISOR        │
                    │    (DynamicSupervisor)         │
                    └───────────────┬────────────────┘
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          │                         │                         │
    ┌─────▼─────┐           ┌───────▼───────┐         ┌───────▼───────┐
    │  SESSION  │           │   BLACKBOARD  │         │     CRON      │
    │  SERVER   │◄─────────►│   (GenServer) │         │   SCHEDULER   │
    │(GenServer)│           └───────────────┘         └───────────────┘
    └─────┬─────┘
          │ dispatches
    ┌─────▼─────────────────────────────────────────────────────┐
    │                      EXECUTOR                              │
    │                     (Task)                                 │
    │                                                            │
    │   ┌──────────────────┬──────────────────┬──────────────┐ │
    │   │   NATIVE TOOLS   │    MCP TOOLS     │  SUB-AGENTS  │ │
    │   │                  │                  │              │ │
    │   │ • FileSystem     │ • filesystem     │ • dispatch   │ │
    │   │ • SafeShell      │ • github         │ • monitor    │ │
    │   │ • Web            │ • postgres       │ • research   │ │
    │   │ • GitHub         │ • any MCP server │ • ...        │ │
    │   │ • Scheduler      │                  │              │ │
    │   │ • GraphMemory    │                  │              │ │
    │   └──────────────────┴──────────────────┴──────────────┘ │
    └────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │    LLM CLIENT     │
                    │ (OpenAI-compatible)│
                    │                   │
                    │ OpenRouter • Z.AI │
                    │ Kimi • Anthropic  │
                    └───────────────────┘
```

---

## Installation

Add `pincer` to your `mix.exs`:

```elixir
def deps do
  [
    {:pincer, "~> 0.1.0"}
  ]
end
```

---

## Quick Start

### 1. Configure your LLM

```elixir
# config/config.exs
config :pincer,
  llm: %{
    "provider" => "openrouter",
    "openrouter" => %{
      "base_url" => "https://openrouter.ai/api/v1/chat/completions",
      "default_model" => "anthropic/claude-sonnet-4"
    }
  }
```

Set your API key:

```bash
export OPENROUTER_API_KEY=sk-or-...
```

### 2. Add to your supervision tree

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    Pincer.Application  # Starts the full Pincer supervision tree
  ]
  
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### 3. Start chatting

```elixir
# Start a session
{:ok, _pid} = Pincer.Session.Supervisor.start_session("user-123")

# Send a message
Pincer.Session.Server.process_input("user-123", "What files are in my workspace?")

# Subscribe to events
Pincer.PubSub.subscribe("session:user-123")
flush()
# => {:agent_thinking, "Using tool: list_files..."}
# => {:agent_response, "I found 42 files in your workspace..."}
```

---

## Defining Custom Tools

```elixir
defmodule MyApp.Tools.Database do
  @behaviour Pincer.Tool

  @impl true
  def spec do
    %{
      name: "query_database",
      description: "Execute a read-only SQL query",
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "SELECT query to execute"
          }
        },
        required: ["query"]
      }
    }
  end

  @impl true
  def execute(%{"query" => query}) do
    # Safety check
    if String.contains?(String.upcase(query), ["DELETE", "DROP", "UPDATE"]) do
      {:error, "Only SELECT queries are allowed"}
    else
      case MyRepo.query(query) do
        {:ok, result} -> {:ok, format_results(result)}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp format_results(%{rows: rows, columns: cols}) do
    # Format for LLM consumption
    header = Enum.join(cols, " | ")
    separator = Enum.map(cols, fn _ -> "---" end) |> Enum.join(" | ")
    body = Enum.map(rows, fn row -> Enum.join(row, " | ") end) |> Enum.join("\n")
    
    "#{header}\n#{separator}\n#{body}"
  end
end
```

Register in `Pincer.Core.Executor`:

```elixir
@native_tools [
  # ... existing tools ...
  MyApp.Tools.Database
]
```

---

## Channels

Pincer supports multiple communication channels out of the box:

### Telegram

```elixir
# config/config.exs
config :pincer, channels: [
  telegram: %{
    "enabled" => true,
    "token_env" => "TELEGRAM_BOT_TOKEN"
  }
]
```

```bash
export TELEGRAM_BOT_TOKEN=your-bot-token
```

### CLI

```bash
# Interactive mode
mix pincer.chat

# Single message
mix pincer.chat -m "What's the status of my last deployment?"
```

### Adding a New Channel

```elixir
defmodule MyApp.Channels.Slack do
  @behaviour Pincer.Channel

  @impl true
  def start_link(config), do: # ...

  @impl true
  def send_message(channel, text), do: # ...
end
```

---

## MCP Integration

Pincer has native, first-class support for the [Model Context Protocol](https://modelcontextprotocol.io/):

```elixir
# config/config.exs
config :pincer, :mcp, %{
  "servers" => %{
    "filesystem" => %{
      "command" => "npx",
      "args" => ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"]
    },
    "github" => %{
      "command" => "npx",
      "args" => ["-y", "@modelcontextprotocol/server-github"]
    },
    "postgres" => %{
      "command" => "uvx",
      "args" => ["mcp-server-postgres", "postgresql://localhost/mydb"]
    }
  }
}
```

Tools are discovered automatically when the MCP Manager starts. No manual registration needed.

---

## Sub-Agents & Blackboard

When tasks need to run in parallel or in the background, dispatch sub-agents:

```elixir
# From within a tool or the executor
Pincer.Tools.Orchestrator.execute(%{
  "goal" => "Research the top 5 competitors and create a summary report"
})

# The main agent continues; sub-agent works independently
# Results are posted to the Blackboard
```

The Blackboard pattern decouples sub-agents from the main session:

```
┌──────────────┐     ┌─────────────┐     ┌──────────────┐
│  Sub-Agent A │────►│             │◄────│  Sub-Agent B │
└──────────────┘     │ BLACKBOARD  │     └──────────────┘
                     │             │
┌──────────────┐     │  Messages   │     ┌──────────────┐
│  Sub-Agent C │────►│  Posted     │◄────│   Session    │
└──────────────┘     │  Here       │     │   (polls)    │
                     └─────────────┘     └──────────────┘
```

---

## Scheduled Tasks

```elixir
# Schedule a task via the Scheduler tool
Pincer.Tools.Scheduler.execute(%{
  "action" => "schedule",
  "prompt" => "Check for security updates",
  "interval" => "daily"
})

# Or via the Cron system
Pincer.Cron.Scheduler.schedule("0 9 * * *", "Morning briefing", "user-123")
```

---

## Memory

Pincer implements a three-layer memory architecture:

| Layer | Storage | Purpose |
|-------|---------|---------|
| **Working** | Session state | Current conversation |
| **Episodic** | Markdown files | Session logs |
| **Semantic** | Graph (SQLite) | Bug/fix history, relationships |

```elixir
# Query the knowledge graph
Pincer.Tools.GraphMemory.execute(%{"filter" => "authentication"})

# Archive old conversations
Pincer.Orchestration.Archivist.start_consolidation("user-123", history)
```

---

## Safety Features

### Loop Detection

The Executor detects when the LLM is stuck calling the same tool repeatedly:

```elixir
# After 3 identical tool_calls in the last 6 messages
# Executor aborts and reports to the session
```

### Recursion Limit

```elixir
# Hard limit on reasoning depth
@max_recursion_depth 10
```

### Approval Workflow

```elixir
# Commands not in the SafeShell whitelist require approval
Pincer.Session.Server.approve_tool("user-123", "call-abc-123")
# or
Pincer.Session.Server.deny_tool("user-123", "call-abc-123")
```

---

## Comparison

| Feature | Pincer | OpenClaw | NanoBot |
|---------|--------|----------|---------|
| Language | Elixir | TypeScript | Python |
| Runtime | BEAM/OTP | Node.js | Python |
| Fault Tolerance | ✅ Supervision trees | ⚠️ External PM | ❌ Manual |
| Hot Reload | ✅ Built-in | ❌ | ❌ |
| MCP Support | ✅ Native | ⚠️ Plugin | ✅ v0.1.4+ |
| Sub-Agents | ✅ Blackboard | ✅ Multi-agent | ✅ SubAgent |
| Human-in-Loop | ✅ Whitelist + approval | ✅ | ⚠️ |
| Lines of Code | ~4k | ~430k | ~4k |

---

## Philosophy

**Doc-First, Test-Driven.** Every feature begins with documentation and tests. If it's not documented, it doesn't exist. If it's not tested, it's broken.

**Single Source of Truth.** The Executor is the orchestrator. Tools are capabilities, not agents. Sub-agents are for parallelism, not complexity.

**Explicit Over Implicit.** Dangerous operations require approval. State transitions are visible. Errors are logged, not swallowed.

---

## Documentation

Full documentation is available at [hexdocs.pm/pincer](https://hexdocs.pm/pincer).

Key modules to explore:

- `Pincer` - Framework overview
- `Pincer.Tool` - Defining custom tools
- `Pincer.Core.Executor` - The reasoning loop
- `Pincer.Session.Server` - Managing conversations
- `Pincer.Orchestration.Blackboard` - Inter-agent communication
- `Pincer.Connectors.MCP` - Model Context Protocol integration

---

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Write tests and documentation first
4. Commit your changes (`git commit -am 'Add some feature'`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create a Pull Request

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

<p align="center">
  <strong>Built with 🔨 in Elixir</strong><br>
  <sub>Because agents deserve better than Python threads.</sub>
</p>
