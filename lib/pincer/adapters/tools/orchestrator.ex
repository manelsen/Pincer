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
  alias Pincer.Core.Orchestration.SubAgentRegistry
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
        "Dispatches a new autonomous Sub-Agent to work on a goal asynchronously. Use this for monitoring, long tasks, or parallel processing. Optionally pins the provider, model, and thinking level for that run. Use action \"status\" with an agent_id to read a dispatched agent's durable run record.",
      parameters: %{
        type: "object",
        properties: %{
          goal: %{
            type: "string",
            description: "The specific goal for the sub-agent. Be descriptive."
          },
          provider: %{
            type: "string",
            description: "Optional LLM provider for this run (requires model)."
          },
          model: %{
            type: "string",
            description: "Optional model identifier for this run (requires provider)."
          },
          thinking_level: %{
            type: "string",
            description: "Optional thinking level forwarded to the LLM provider."
          },
          action: %{
            type: "string",
            enum: ["start", "status"],
            description: "start (default) dispatches a new agent; status reads a run record."
          },
          agent_id: %{
            type: "string",
            description: "Agent id to inspect when action is \"status\"."
          }
        },
        required: []
      }
    }
  end

  @doc """
  Dispatches a new Sub-Agent with the given goal, or reports a run's status.

  Creates and starts a new Sub-Agent process that will work autonomously on
  the specified goal. The agent will report progress and results to the
  Blackboard, which can be monitored using `Pincer.Adapters.Tools.BlackboardReader`.

  ## Parameters

    * `goal` (required for `"start"`) - A clear, specific description of what
      the sub-agent should accomplish.
    * `provider`, `model` (optional) - Pin the LLM provider/model for this run.
      Both must be present to take effect.
    * `thinking_level` (optional) - Forwarded to the LLM provider.
    * `action` (optional) - `"start"` (default) or `"status"`.
    * `agent_id` (required for `"status"`) - The agent whose run record to read.

  ## Returns

    * `{:ok, message}` - Success message including the generated agent ID, or
      the formatted run record for `"status"`.
    * `{:error, reason}` - Failure message with details.

  ## Examples

      iex> Pincer.Adapters.Tools.Orchestrator.execute(%{"goal" => "Find all TODO comments"})
      {:ok, "Sub-Agent detached successfully. ID: agent_a1b2c3. Monitor the Blackboard for updates."}

      iex> Pincer.Adapters.Tools.Orchestrator.execute(%{})
      ** (FunctionClauseError) no function clause matching

  ## Implementation Notes

  - Agent IDs are 16-character hex strings prefixed with "agent_"
  - Sub-Agents run as supervised `:temporary` children under `SubAgentSupervisor`
  - Reservations are admitted by `SubAgentRegistry` before any child starts
  """
  @spec execute(map(), map()) :: execute_result()
  def execute(args, context \\ %{})

  def execute(%{"action" => "status"} = args, _context) do
    case Map.get(args, "agent_id") do
      id when is_binary(id) and id != "" ->
        case SubAgent.run_info(id) do
          {:ok, info} ->
            {:ok, format_run_info(info)}

          {:error, :not_found} ->
            {:error, "No run record found for agent #{id}."}

          {:error, reason} ->
            {:error, "Failed to read run record for agent #{id}: #{inspect(reason)}"}
        end

      _ ->
        {:error, "dispatch_agent action 'status' requires an 'agent_id' parameter."}
    end
  end

  def execute(%{"goal" => goal} = args, context) when is_binary(goal) and goal != "" do
    parent_session_id = Map.get(context, "session_id") || Map.get(args, "session_id")
    parent_workspace_path = Map.get(context, "workspace_path") || Map.get(args, "workspace_path")
    id = "agent_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    opts =
      [
        goal: goal,
        id: id,
        parent_session_id: parent_session_id,
        parent_workspace_path: parent_workspace_path
      ] ++ model_override_opts(args)

    case SubAgentRegistry.reserve(id, parent_session_id) do
      :ok ->
        start_child(opts, id)

      {:error, :global_limit} ->
        {:error, limit_message("global", :max_subagents, 32)}

      {:error, :session_limit} ->
        {:error, limit_message("session", :max_subagents_per_session, 8)}
    end
  end

  def execute(args, _context) do
    {:error, "dispatch_agent requires a 'goal' parameter. Got keys: #{inspect(Map.keys(args))}"}
  end

  defp start_child(opts, id) do
    case SubAgent.start_supervised(opts, sub_agent_supervisor()) do
      {:ok, pid} ->
        :ok = SubAgentRegistry.track(id, pid)
        {:ok, "Sub-Agent detached successfully. ID: #{id}. Monitor the Blackboard for updates."}

      {:error, reason} ->
        SubAgentRegistry.release(id)
        {:error, "Failed to dispatch agent: #{inspect(reason)}"}
    end
  end

  defp model_override_opts(args) do
    provider = Map.get(args, "provider")
    model = Map.get(args, "model")
    thinking_level = Map.get(args, "thinking_level")

    if is_binary(provider) and provider != "" and is_binary(model) and model != "" do
      override = %{provider: provider, model: model}

      override =
        if is_binary(thinking_level) and thinking_level != "" do
          Map.put(override, :thinking_level, thinking_level)
        else
          override
        end

      [model_override: override]
    else
      []
    end
  end

  defp limit_message(scope, key, default) do
    cap = Application.get_env(:pincer, key, default)
    "Sub-agent limit reached: #{scope} cap of #{cap} active sub-agents."
  end

  defp format_run_info(info) do
    metadata = Map.get(info, :metadata) || %{}

    [
      "Sub-agent #{Map.get(info, :id)}",
      "Status: #{Map.get(info, :status)}",
      "Step count: #{Map.get(info, :step_count, 0)}",
      metadata_line(metadata, :goal, "Goal"),
      metadata_line(metadata, :result, "Result"),
      timestamp_line(info)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp metadata_line(metadata, key, label) do
    case metadata_value(metadata, key) do
      nil -> nil
      "" -> nil
      value -> "#{label}: #{value}"
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp timestamp_line(info) do
    case Map.get(info, :updated_at) do
      nil -> nil
      %DateTime{} = value -> "Updated: #{DateTime.to_iso8601(value)}"
      value -> "Updated: #{value}"
    end
  end

  defp sub_agent_supervisor do
    Application.get_env(
      :pincer,
      :sub_agent_supervisor,
      Pincer.Core.Orchestration.SubAgentSupervisor
    )
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
