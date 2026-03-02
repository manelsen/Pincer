defmodule Pincer do
  @moduledoc """
  Pincer is an autonomous AI agent framework built on the BEAM ecosystem.

  Designed for developers who need AI agents that actually work in production,
  Pincer combines the reliability of OTP with the flexibility of Model Context
  Protocol (MCP) to create agents that can reason, plan, and execute complex
  tasks autonomously.

  ## Why Pincer?

  Most AI agent frameworks treat the LLM as the orchestrator. Pincer flips this:
  the BEAM orchestrates, the LLM reasons. This means your agents get:

  - **Supervision trees** that restart failed tasks automatically
  - **Hot code reloading** without losing agent state
  - **Massive concurrency** via lightweight processes
  - **Built-in observability** through OTP tooling

  ## Architecture

  Pincer implements a **Unified Executor** pattern—a single, polymath agent
  that reasons through problems using a curated toolbox rather than a maze
  of specialized micro-agents. When parallelism is needed, sub-agents can
  be dispatched to work independently while communicating through a shared
  Blackboard.

      ┌─────────────────────────────────────────────────┐
      │                   Session                        │
      │  (GenServer - holds conversation state)          │
      └──────────────────────┬──────────────────────────┘
                             │
      ┌──────────────────────▼──────────────────────────┐
      │               Executor                           │
      │  (Task - runs reasoning loop)                    │
      │                                                  │
      │   ┌──────────┐  ┌──────────┐  ┌──────────┐      │
      │   │  Native  │  │   MCP    │  │  Sub-    │      │
      │   │  Tools   │  │ Connect  │  │ Agents   │      │
      │   └──────────┘  └──────────┘  └──────────┘      │
      └─────────────────────────────────────────────────┘

  ## Key Features

  ### Native Tools
  Built-in tools for common operations: file system, git, web requests,
  scheduling, and safe shell execution with approval workflows.

  ### MCP Integration
  Connect to any Model Context Protocol server to extend capabilities
  dynamically. Tools are discovered at runtime and merged with native tools.

  ### Sub-Agents & Blackboard
  Dispatch autonomous sub-agents for parallel work. They communicate
  asynchronously through a shared Blackboard pattern—no message passing hell.

  ### Human-in-the-Loop
  Dangerous operations require explicit approval. The executor pauses and
  waits for user confirmation before proceeding.

  ## Quick Start

      # Start a session with a goal
      {:ok, session} = Pincer.Session.Server.start_link(
        id: "my-session",
        system_prompt: "You are a helpful coding assistant."
      )

      # Send a message
      Pincer.Session.Server.send_message(session, "Create a new Elixir project")

      # Subscribe to events
      Pincer.PubSub.subscribe("session:my-session")
      flush()  # => {:agent_thinking, "Analyzing request..."}

  ## Philosophy

  **Doc-First, Test-Driven.** Every feature begins with documentation and
  tests. If it's not documented, it doesn't exist. If it's not tested, it's
  broken.

  **Single Source of Truth.** The Executor is the orchestrator. Tools are
  capabilities, not agents. Sub-agents are for parallelism, not complexity.

  **Explicit Over Implicit.** Dangerous operations require approval. State
  transitions are visible. Errors are logged, not swallowed.

  ## Configuration

  Pincer uses a layered configuration system. See `Pincer.Config` for details.

      # config/config.exs
      config :pincer,
        llm: [
          provider: :anthropic,
          model: "claude-sonnet-4-20250514"
        ],
        mcp: [
          servers: ["filesystem", "github"]
        ]

  ## See Also

  - `Pincer.Tool` - Defining custom tools
  - `Pincer.Core.Executor` - The reasoning loop
  - `Pincer.Session.Server` - Managing conversations
  - `Pincer.Orchestration.Blackboard` - Inter-agent communication
  """

  @doc """
  Returns a greeting for health checks and basic connectivity tests.

  This function exists primarily for CI/CD pipelines and health endpoints
  to verify the application started correctly.

  ## Examples

      iex> Pincer.hello()
      :world

  """
  @spec hello() :: :world
  def hello do
    :world
  end
end
