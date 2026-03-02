defmodule Pincer.Orchestration.Blackboard do
  @moduledoc """
  A central message repository enabling decoupled communication between agents.

  The Blackboard implements the **Blackboard Pattern**, a collaborative problem-solving
  architecture where multiple independent agents (knowledge sources) contribute to a
  shared workspace. This pattern is particularly effective for:

  - **Decoupled communication**: Agents don't need to know about each other
  - **Asynchronous coordination**: Results are posted and polled independently
  - **Observability**: All agent activity is centralized and queryable
  - **Fault isolation**: One agent's failure doesn't affect others

  ## Architecture

      ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
      │   SubAgent   │     │   SubAgent   │     │   MainAgent  │
      │   (writer)   │     │   (writer)   │     │   (reader)   │
      └──────┬───────┘     └──────┬───────┘     └──────┬───────┘
             │                    │                    │
             │ post/2             │ post/2             │ fetch_new/1
             ▼                    ▼                    ▼
      ┌─────────────────────────────────────────────────────────┐
      │                      BLACKBOARD                         │
      │  ┌─────────────────────────────────────────────────┐   │
      │  │  Messages: [{id, agent_id, content, timestamp}] │   │
      │  └─────────────────────────────────────────────────┘   │
      └─────────────────────────────────────────────────────────┘

  ## Message Format

  Each message on the Blackboard contains:

  - `:id` - Monotonically increasing integer (used for polling)
  - `:agent_id` - Identifier of the posting agent
  - `:content` - The message payload (string)
  - `:timestamp` - UTC datetime when posted

  ## Usage Pattern

  The typical flow is:

  1. **Main Agent** spawns multiple SubAgents
  2. **SubAgents** post progress/results to Blackboard
  3. **Main Agent** periodically polls for new messages
  4. **Main Agent** processes results and takes action

  ## Examples

      # Start the Blackboard (typically done by supervisor)
      {:ok, _pid} = Pincer.Orchestration.Blackboard.start_link([])

      # SubAgent posts a message
      msg_id = Pincer.Orchestration.Blackboard.post("agent_001", "Task started")

      # Main Agent polls for new messages
      {messages, last_id} = Pincer.Orchestration.Blackboard.fetch_new(0)
      # => {[%{id: 1, agent_id: "agent_001", content: "Task started", ...}], 1}

      # Later, poll again from last seen ID
      {new_messages, last_id} = Pincer.Orchestration.Blackboard.fetch_new(last_id)

  ## Implementation Notes

  - Messages are stored in reverse chronological order (newest first)
  - This enables O(1) prepend for new messages
  - `fetch_new/1` reverses results to return oldest-to-newest order
  - The Blackboard is a named process registered as `__MODULE__`
  """

  use GenServer
  require Logger

  @type message :: %{
          id: pos_integer(),
          agent_id: String.t(),
          content: String.t(),
          timestamp: DateTime.t()
        }

  @type state :: %{
          messages: [message()],
          next_id: pos_integer()
        }

  # --- API ---

  @doc """
  Starts the Blackboard GenServer.

  The Blackboard is registered under its module name, allowing global access
  via `post/2` and `fetch_new/1` without needing the PID.

  ## Returns

    * `{:ok, pid}` - The Blackboard process started successfully

  ## Examples

      iex> Pincer.Orchestration.Blackboard.start_link([])
      {:ok, #PID<0.100.0>}

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{messages: [], next_id: 1}, name: __MODULE__)
  end

  @doc """
  Posts a new message to the Blackboard.

  Messages are timestamped automatically and assigned a unique, monotonically
  increasing ID. The ID can be used by readers to track which messages they've
  already processed.

  ## Parameters

    * `agent_id` - Identifier of the posting agent (e.g., "sub_agent_001")
    * `content` - The message content/payload

  ## Returns

    * The message ID (positive integer) assigned to this message

  ## Examples

      iex> Pincer.Orchestration.Blackboard.post("agent_001", "Started processing")
      1

      iex> Pincer.Orchestration.Blackboard.post("agent_002", "Found 5 files")
      2

  """
  @spec post(String.t(), String.t()) :: pos_integer()
  def post(agent_id, content) do
    GenServer.call(__MODULE__, {:post, agent_id, content})
  end

  @doc """
  Fetches all messages posted after the given ID.

  This is the primary polling mechanism for agents to receive updates.
  The returned messages are ordered oldest-to-newest, making sequential
  processing natural.

  ## Parameters

    * `since_id` - Only return messages with ID greater than this value.
      Use `0` to fetch all messages from the beginning.

  ## Returns

    * `{messages, last_seen_id}` - A tuple containing:
      - `messages` - List of new messages (may be empty)
      - `last_seen_id` - The highest ID in the returned messages,
        or `since_id` if no new messages exist

  ## Examples

      # Fetch all messages from the beginning
      iex> {messages, last_id} = Pincer.Orchestration.Blackboard.fetch_new(0)
      iex> length(messages)
      3
      iex> last_id
      3

      # Poll for new messages since last check
      iex> {new_messages, new_last_id} = Pincer.Orchestration.Blackboard.fetch_new(last_id)
      iex> new_messages
      []

      # After another agent posts...
      iex> {new_messages, _} = Pincer.Orchestration.Blackboard.fetch_new(3)
      iex> hd(new_messages).content
      "Task completed"

  """
  @spec fetch_new(non_neg_integer()) :: {[message()], non_neg_integer()}
  def fetch_new(since_id) do
    GenServer.call(__MODULE__, {:fetch, since_id})
  end

  # --- Callbacks ---

  @impl true
  def init(state) do
    Logger.info("Blackboard started.")
    {:ok, state}
  end

  @impl true
  def handle_call({:post, agent_id, content}, _from, state) do
    id = state.next_id
    msg = %{id: id, agent_id: agent_id, content: content, timestamp: DateTime.utc_now()}

    {:reply, id, %{state | messages: [msg | state.messages], next_id: id + 1}}
  end

  @impl true
  def handle_call({:fetch, since_id}, _from, state) do
    new_messages =
      state.messages
      |> Enum.take_while(fn msg -> msg.id > since_id end)
      |> Enum.reverse()

    last_id = if Enum.empty?(new_messages), do: since_id, else: List.last(new_messages).id

    {:reply, {new_messages, last_id}, state}
  end
end
