defmodule Pincer.Adapters.Tools.Orchestrator do
  @moduledoc """
  Tool for dispatching autonomous Sub-Agents to work on goals asynchronously.

  This tool enables parallel processing and background task execution by spawning
  independent Sub-Agents that operate autonomously. Each Sub-Agent has its own
  execution context and reports progress to the shared Blackboard.

  ## Use Cases

  - **Parallel Processing**: Dispatch multiple agents to work on independent tasks
  - **Long-running Tasks**: Offload time-consuming operations to background agents
  - **Monitoring**: Deploy agents to watch for specific conditions or events
  - **Research Tasks**: Send agents to gather information while continuing main work

  ## Architecture

      ┌─────────────┐     ┌─────────────┐
      │   Session   │────▶│ Orchestrator│
      └─────────────┘     └──────┬──────┘
                                 │ dispatch
                                 ▼
      ┌─────────────┐     ┌─────────────┐
      │  Blackboard │◀────│  Sub-Agent  │
      └─────────────┘     └─────────────┘

  ## Examples

      # Dispatch an agent for code review
      Pincer.Adapters.Tools.Orchestrator.execute(%{"goal" => "Review all files in lib/ for TODO comments"})

      # Dispatch an agent for monitoring
      Pincer.Adapters.Tools.Orchestrator.execute(%{"goal" => "Watch test.log for ERROR patterns"})

  ## Security Considerations

  Sub-Agents inherit the same permissions as the parent session. Be cautious when
  dispatching agents with access to sensitive resources. Agent IDs are randomly
  generated using cryptographically strong random bytes.

  ## See Also

  - `Pincer.Adapters.Tools.BlackboardReader` - Read messages from dispatched agents
  - `Pincer.Core.Orchestration.SubAgent` - Sub-Agent implementation
  - `Pincer.Core.Orchestration.Blackboard` - Message bus for agent communication
  """

  @behaviour Pincer.Ports.Tool
  alias Pincer.Core.Orchestration.SubAgent
  alias Pincer.Core.Orchestration.Blackboard

  @type spec :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @type execute_result :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Returns the tool specification for LLM function calling.

  ## Returns

      %{
        name: "dispatch_agent",
        description: "Dispatches a new autonomous Sub-Agent...",
        parameters: %{
          type: "object",
          properties: %{
            goal: %{type: "string", description: "The specific goal for the sub-agent..."}
          },
          required: ["goal"]
        }
      }
  """
  @spec spec() :: spec()
  def spec do
    %{
      name: "dispatch_agent",
      description:
        "Dispatches a new autonomous Sub-Agent to work on a goal asynchronously. Use this for monitoring, long tasks, or parallel processing.",
      parameters: %{
        type: "object",
        properties: %{
          goal: %{
            type: "string",
            description: "The specific goal for the sub-agent. Be descriptive."
          }
        },
        required: ["goal"]
      }
    }
  end

  @doc """
  Dispatches a new Sub-Agent with the given goal.

  Creates and starts a new Sub-Agent process that will work autonomously on
  the specified goal. The agent will report progress and results to the
  Blackboard, which can be monitored using `Pincer.Adapters.Tools.BlackboardReader`.

  ## Parameters

    * `goal` (required) - A clear, specific description of what the sub-agent
      should accomplish. More descriptive goals lead to better results.

  ## Returns

    * `{:ok, message}` - Success message including the generated agent ID
    * `{:error, reason}` - Failure message with details

  ## Examples

      iex> Pincer.Adapters.Tools.Orchestrator.execute(%{"goal" => "Find all TODO comments"})
      {:ok, "Sub-Agent detached successfully. ID: agent_a1b2c3. Monitor the Blackboard for updates."}

      iex> Pincer.Adapters.Tools.Orchestrator.execute(%{})
      ** (FunctionClauseError) no function clause matching

  ## Implementation Notes

  - Agent IDs are 6-character hex strings prefixed with "agent_"
  - Agents are spawned as GenServer processes (not supervised in MVP)
  - In production, consider using DynamicSupervisor for better fault tolerance
  """
  @spec execute(%{String.t() => String.t()}) :: execute_result()
  def execute(%{"goal" => goal}) do
    id = "agent_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    case GenServer.start(SubAgent, goal: goal, id: id) do
      {:ok, _pid} ->
        {:ok, "Sub-Agent detached successfully. ID: #{id}. Monitor the Blackboard for updates."}

      {:error, reason} ->
        {:error, "Failed to dispatch agent: #{inspect(reason)}"}
    end
  end
end

defmodule Pincer.Adapters.Tools.BlackboardReader do
  @moduledoc """
  Tool for reading messages from the Sub-Agent Blackboard.

  The Blackboard is a shared message bus where Sub-Agents post their progress,
  findings, and results. This tool allows the main session to monitor and
  retrieve messages from all dispatched agents.

  ## Purpose

  - Monitor progress of background Sub-Agents
  - Collect results from parallel agent executions
  - Debug agent behavior and outputs
  - Coordinate work between main session and agents

  ## Message Format

  Each message on the Blackboard contains:

      %{
        agent_id: "agent_a1b2c3",
        timestamp: ~U[2026-02-20 14:30:00Z],
        content: "Found 5 TODO comments in lib/"
      }

  ## Examples

      # Read all messages from the Blackboard
      Pincer.Adapters.Tools.BlackboardReader.execute(%{})

      # Limit to last 5 messages
      Pincer.Adapters.Tools.BlackboardReader.execute(%{"limit" => 5})

  ## Output Format

  Messages are formatted as:

      [agent_a1b2c3 @ 2026-02-20 14:30:00Z]: Found 5 TODO comments
      [agent_d4e5f6 @ 2026-02-20 14:31:00Z]: Analysis complete

  ## See Also

  - `Pincer.Adapters.Tools.Orchestrator` - Dispatch new Sub-Agents
  - `Pincer.Core.Orchestration.Blackboard` - Blackboard implementation
  """

  @behaviour Pincer.Ports.Tool
  alias Pincer.Core.Orchestration.Blackboard

  @type message :: %{
          agent_id: String.t(),
          timestamp: DateTime.t(),
          content: String.t()
        }

  @type spec :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @type execute_result :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Returns the tool specification for LLM function calling.

  ## Returns

      %{
        name: "read_blackboard",
        description: "Reads recent messages from the Sub-Agent Blackboard.",
        parameters: %{
          type: "object",
          properties: %{
            limit: %{type: "integer", description: "Number of recent messages...", default: 10}
          }
        }
      }
  """
  @spec spec() :: spec()
  def spec do
    %{
      name: "read_blackboard",
      description: "Reads recent messages from the Sub-Agent Blackboard.",
      parameters: %{
        type: "object",
        properties: %{
          limit: %{
            type: "integer",
            description: "Number of recent messages to read (default 10)",
            default: 10
          }
        }
      }
    }
  end

  @doc """
  Reads and returns messages from the Sub-Agent Blackboard.

  Fetches all messages posted by Sub-Agents and returns them in a
  human-readable format with agent IDs and timestamps.

  ## Parameters

    * `limit` (optional) - Maximum number of messages to return. Defaults to 10.
      Currently not enforced as all messages are fetched.

  ## Returns

    * `{:ok, messages}` - Formatted string with all messages, one per line
    * `{:ok, "Blackboard is empty."}` - When no messages exist

  ## Examples

      iex> Pincer.Adapters.Tools.BlackboardReader.execute(%{})
      {:ok, "[agent_abc @ 2026-02-20 14:30:00Z]: Task started\\n[agent_abc @ 2026-02-20 14:31:00Z]: Found 5 items"}

      iex> Pincer.Adapters.Tools.BlackboardReader.execute(%{"limit" => 5})
      {:ok, "[agent_xyz @ 2026-02-20 15:00:00Z]: Analysis complete"}

  ## Note

  In the current implementation, the `limit` parameter is accepted but all
  messages are returned. Future versions will respect this parameter and
  support cursor-based pagination for efficient message retrieval.
  """
  @spec execute(map()) :: execute_result()
  def execute(_args) do
    {msgs, _last_id} = Blackboard.fetch_new(0)

    if Enum.empty?(msgs) do
      {:ok, "Blackboard is empty."}
    else
      output =
        msgs
        |> Enum.map(fn msg -> "[#{msg.agent_id} @ #{msg.timestamp}]: #{msg.content}" end)
        |> Enum.join("\n")

      {:ok, output}
    end
  end
end
