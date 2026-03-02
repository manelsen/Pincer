defmodule Pincer.Session.Server do
  @moduledoc """
  Core session GenServer implementing the Pincer Brain.

  This is the central orchestrator for a user session, handling input processing,
  LLM coordination, and event broadcasting. It follows a ports-and-adapters
  architecture: receives input via GenServer calls and emits events via PubSub.

  ## Session Lifecycle

  A session can be in one of two modes:

  1. **Bootstrapping Mode** - When `SOUL.md` doesn't exist, the session enters
     a bootstrap flow to collect essential information (name, preferences, etc.)
     before transitioning to normal operation.

  2. **Normal Mode** - Full operational mode with:
     - System prompt loaded from `IDENTITY.md`, `SOUL.md`, and `USER.md`
     - Persistent conversation history from storage
     - Blackboard integration for sub-agent coordination
     - Scheduled task support via Scheduler

  ## Architecture

      ┌─────────────────┐     ┌─────────────────┐
      │  External API   │────▶│  Session.Server │
      │  (CLI/HTTP/WS)  │     │   (GenServer)   │
      └─────────────────┘     └────────┬────────┘
                                        │
                      ┌─────────────────┼─────────────────┐
                      ▼                 ▼                 ▼
              ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
              │   Executor   │  │  Blackboard  │  │   PubSub     │
              │  (LLM calls) │  │ (Sub-agents) │  │ (Events)     │
              └──────────────┘  └──────────────┘  └──────────────┘

  ## PubSub Events

  The server broadcasts events to `session:{session_id}` topic:

  | Event | Description |
  |-------|-------------|
  | `{:agent_status, message}` | Status updates from SME or scheduled tasks |
  | `{:agent_thinking, message}` | Progress indicators during tool execution |
  | `{:agent_response, response}` | Final response to user |
  | `{:agent_error, reason}` | Error notifications |
  | `{:tool_approval_request, tool_name, call_id}` | Request for tool approval |

  ## Tool Approval Flow

  When an Executor encounters a tool requiring user approval:

  1. Executor sends `{:tool_approval_request, tool_name, call_id}` to session
  2. Session broadcasts the request via PubSub
  3. External UI prompts user for decision
  4. UI calls `approve_tool/2` or `deny_tool/2`
  5. Session forwards decision to the active worker process

      Session.Server                Executor              User UI
           │                           │                      │
           │◀──── tool_approval_req ───│                      │
           │                           │                      │
           │──── broadcast to PubSub ──▶                      │
           │                           │                      │
           │                           │◀── approve_tool ─────│
           │                           │                      │
           │                           ──▶ executes tool ────▶│

  ## Blackboard Heartbeat Pattern

  The server implements a heartbeat (every 10s) to poll the Blackboard for
  sub-agent updates:

  1. `handle_info(:heartbeat, state)` triggers every 10 seconds
  2. Calls `Blackboard.fetch_new(last_id)` to get new messages
  3. Appends updates to conversation history as system messages
  4. If session is idle, spawns evaluation task to decide if user should be notified

  This enables background sub-agents to report progress without blocking
  the main conversation flow.

  ## Examples

      # Start a session
      {:ok, pid} = Pincer.Session.Server.start_link(session_id: "user_123")

      # Process user input
      {:ok, :started} = Pincer.Session.Server.process_input("user_123", "Create a todo app")

      # Approve a tool call
      :ok = Pincer.Session.Server.approve_tool("user_123", "call_abc123")

      # Change model mid-session
      :ok = Pincer.Session.Server.set_model("user_123", :anthropic, "claude-3-opus")

      # Check session status
      {:ok, %{status: :idle, history: [...], model_override: nil}} = 
        Pincer.Session.Server.get_status("user_123")
  """
  use GenServer, restart: :transient
  require Logger

  alias Pincer.LLM.Client
  alias Pincer.Storage
  alias Pincer.Core.Executor
  alias Pincer.Core.ErrorUX
  alias Pincer.Core.RetryPolicy
  alias Pincer.Core.SubAgentProgress
  alias Pincer.Core.Telemetry, as: CoreTelemetry
  alias Pincer.PubSub

  @identity_file "IDENTITY.md"
  @soul_file "SOUL.md"
  @user_file "USER.md"

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    if File.exists?(@soul_file) do
      persisted = Storage.get_messages(session_id)

      history =
        if Enum.empty?(persisted),
          do: [%{"role" => "system", "content" => get_system_prompt()}],
          else: [%{"role" => "system", "content" => get_system_prompt()} | persisted]

      case Process.whereis(Pincer.Orchestration.Blackboard) do
        nil -> Pincer.Orchestration.Blackboard.start_link([])
        _ -> :ok
      end

      # Subscribe to global system updates (for hot-swapping prompts without restart)
      PubSub.subscribe("system:updates")

      Pincer.Orchestration.Scheduler.start_link(session_id: session_id)
      Process.send_after(self(), :heartbeat, 5000)

      {:ok,
       %{
         mode: :normal,
         session_id: session_id,
         history: history,
         status: :idle,
         worker_pid: nil,
         last_blackboard_id: 0,
         subagent_progress_tracker: %{},
         model_override: nil
       }}
    else
      {:ok,
       %{
         mode: :bootstrapping,
         session_id: session_id,
         current_step: :name,
         responses: %{},
         worker_pid: nil,
         last_blackboard_id: 0,
         subagent_progress_tracker: %{},
         model_override: nil
       }}
    end
  end

  # --- Input (Driving Port) ---

  @impl true
  def handle_call({:process_input, input}, _from, %{mode: :normal} = state) do
    # input may be a plain String.t() or a [map()] list of multimodal parts.
    text_for_storage = content_to_text(input)
    Storage.save_message(state.session_id, "user", text_for_storage)
    Pincer.Session.Logger.log(state.session_id, "user", text_for_storage)
    user_msg = %{"role" => "user", "content" => input}
    new_history = state.history ++ [user_msg]

    cond do
      state.status == :working ->
        IO.puts("DEBUG: [SESSION] #{state.session_id} busy. Just archiving message.")
        {:reply, {:ok, :queued}, %{state | history: new_history}}

      is_just_chat?(input) ->
        IO.puts("DEBUG: [SESSION] #{state.session_id} Quick chat detected.")

        Task.start(fn ->
          quick_assistant_reply(
            self(),
            state.session_id,
            new_history,
            input,
            state.model_override
          )
        end)

        {:reply, {:ok, :butler_notified}, %{state | history: new_history}}

      true ->
        IO.puts("DEBUG: [SESSION] #{state.session_id} Starting Polymath Executor.")
        long_term_memory = if File.exists?("MEMORY.md"), do: File.read!("MEMORY.md"), else: ""

        executor_opts = [
          model_override: state.model_override,
          long_term_memory: long_term_memory
        ]

        {:ok, pid} = Executor.start(self(), state.session_id, new_history, executor_opts)

        {:reply, {:ok, :started},
         %{state | history: new_history, worker_pid: pid, status: :working}}
    end
  end

  @impl true
  def handle_call({:set_model, provider, model}, _from, state) do
    Logger.info("[SESSION] #{state.session_id} Model override: #{provider}:#{model}")

    if state.worker_pid && Process.alive?(state.worker_pid) do
      Logger.info(
        "[SESSION] Notifying active worker #{inspect(state.worker_pid)} of model change."
      )

      send(state.worker_pid, {:model_changed, provider, model})
    end

    {:reply, :ok, %{state | model_override: %{provider: provider, model: model}}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call({:approve_tool, call_id}, _from, state) do
    if state.worker_pid do
      send(state.worker_pid, {:tool_approval, call_id, :granted})
      {:reply, :ok, state}
    else
      {:reply, {:error, :no_active_worker}, state}
    end
  end

  @impl true
  def handle_call({:deny_tool, call_id}, _from, state) do
    if state.worker_pid do
      send(state.worker_pid, {:tool_approval, call_id, :denied})
      {:reply, :ok, state}
    else
      {:reply, {:error, :no_active_worker}, state}
    end
  end

  # --- Output (Driven Port via Event Bus) ---

  defp publish(session_id, event) do
    Logger.info("[PUB/SUB] Broadcasting to session:#{session_id} event: #{inspect(event)}")
    PubSub.broadcast("session:#{session_id}", event)
  end

  # --- Event Handlers ---

  @impl true
  def handle_info({:assistant_reply_finished, response}, state) do
    new_history = state.history ++ [%{"role" => "assistant", "content" => response}]
    Pincer.Session.Logger.log(state.session_id, "assistant", response)
    check_consolidation_trigger(state.session_id, new_history)
    {:noreply, %{state | history: new_history}}
  end

  @impl true
  def handle_info({:sme_status, role, status}, state) do
    msg = "📐 **#{String.capitalize(to_string(role))}**: #{status}"
    publish(state.session_id, {:agent_status, msg})

    {:noreply,
     %{
       state
       | history: state.history ++ [%{"role" => "system", "content" => "[SME STATUS]: #{msg}"}]
     }}
  end

  @impl true
  def handle_info({:sme_tool_use, tools}, state) do
    publish(state.session_id, {:agent_thinking, "Executing: #{tools}..."})
    {:noreply, state}
  end

  @impl true
  def handle_info({:sme_update, role, content}, state) do
    update_msg = %{"role" => "system", "content" => "[#{role} UPDATE]: #{content}"}
    {:noreply, %{state | history: state.history ++ [update_msg]}}
  end

  @impl true
  def handle_info({:executor_finished, final_history, response}, state) do
    Storage.save_message(state.session_id, "assistant", response)
    Pincer.Session.Logger.log(state.session_id, "assistant", response)
    check_consolidation_trigger(state.session_id, final_history)
    publish(state.session_id, {:agent_response, response})
    {:noreply, %{state | history: final_history, status: :idle, worker_pid: nil}}
  end

  @impl true
  def handle_info({:executor_failed, reason}, state) do
    CoreTelemetry.emit_error(reason, %{scope: :executor, component: :session_server})

    if RetryPolicy.transient?(reason) do
      Logger.warning("[SESSION] Executor failed (transient): #{inspect(reason)}")
    else
      Logger.error("[SESSION] Executor failed: #{inspect(reason)}")
    end

    publish(state.session_id, {:agent_error, ErrorUX.friendly(reason, scope: :executor)})
    {:noreply, %{state | status: :idle, worker_pid: nil}}
  end

  @impl true
  def handle_info({:agent_stream_token, token}, state) do
    publish(state.session_id, {:agent_partial, token})
    {:noreply, state}
  end

  @impl true
  def handle_info({:scheduler_trigger, task_desc}, state) do
    Logger.info("[SESSION] ⏰ Scheduled Task Triggered: #{task_desc}")
    publish(state.session_id, {:agent_status, "⏰ **Scheduled Task**: #{task_desc}"})

    id = "cron_" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))

    case GenServer.start(Pincer.Orchestration.SubAgent, goal: task_desc, id: id) do
      {:ok, _pid} ->
        publish(
          state.session_id,
          {:agent_status, "🚀 Sub-Agent #{id} started for: #{task_desc}"}
        )

      {:error, reason} ->
        Logger.error("Failed to spawn scheduled agent: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, 10000)

    case Pincer.Orchestration.Blackboard.fetch_new(state.last_blackboard_id) do
      {[], _} ->
        {:noreply, state}

      {messages, new_last_id} ->
        {progress_notifications, progress_tracker, needs_review?} =
          SubAgentProgress.notifications(messages, state.subagent_progress_tracker)

        Enum.each(progress_notifications, fn message ->
          publish(state.session_id, {:agent_status, message})
        end)

        updates =
          messages
          |> Enum.map(fn msg -> "[SUB-AGENT #{msg.agent_id}]: #{msg.content}" end)
          |> Enum.join("\n")

        system_msg = %{
          "role" => "system",
          "content" =>
            "SYSTEM UPDATE (Blackboard):\n#{updates}\n\nDECISION REQUIRED: Does this update require notifying the user? If yes, respond to the user. If no, just acknowledge."
        }

        new_history = state.history ++ [system_msg]

        if state.status == :idle and needs_review? do
          Task.start(fn ->
            evaluate_blackboard_update(
              self(),
              state.session_id,
              new_history,
              state.model_override
            )
          end)
        end

        {:noreply,
         %{
           state
           | history: new_history,
             last_blackboard_id: new_last_id,
             subagent_progress_tracker: progress_tracker
         }}
    end
  end

  @impl true
  def handle_info({:cron_trigger, prompt}, state) do
    Logger.info("[SESSION] Triggering Autonomous Trigger for #{state.session_id}")
    publish(state.session_id, {:agent_status, "⏰ **Time Trigger Reached**..."})

    system_msg = %{
      "role" => "user",
      "content" =>
        "[SYSTEM/CRON AUTOMATIC TRIGGER]: The scheduled time for this task has arrived. The instruction attached to this alarm is: '#{prompt}'. Execute this instruction now and respond to the user immediately."
    }

    new_history = state.history ++ [system_msg]

    cond do
      state.status == :working ->
        # If already busy reasoning, just queue in history to avoid corrupting the PID
        {:noreply, %{state | history: new_history}}

      true ->
        long_term_memory = if File.exists?("MEMORY.md"), do: File.read!("MEMORY.md"), else: ""
        executor_opts = [model_override: state.model_override, long_term_memory: long_term_memory]

        {:ok, pid} = Executor.start(self(), state.session_id, new_history, executor_opts)
        {:noreply, %{state | history: new_history, worker_pid: pid, status: :working}}
    end
  end

  @impl true
  def handle_info({:system_update_prompt}, state) do
    Logger.info(
      "[SESSION] #{state.session_id} RECEIVED hot-swap request. Updating System Prompt NOW."
    )

    new_system_msg = %{"role" => "system", "content" => get_system_prompt()}

    # Replace the first message in history (which is always the system prompt)
    new_history =
      case state.history do
        [%{"role" => "system"} | rest] -> [new_system_msg | rest]
        other -> [new_system_msg | other]
      end

    {:noreply, %{state | history: new_history}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internal Logic ---

  defp check_consolidation_trigger(session_id, history) do
    window_size = 128_000
    usage = Pincer.Utils.TokenCounter.utilization(history, window_size)

    if usage > 20.0 do
      PubSub.broadcast(
        "session:#{session_id}",
        {:agent_thinking, "⚠️ Memory at 20% (#{Float.round(usage, 1)}%). Starting Archivist..."}
      )

      Pincer.Orchestration.Archivist.start_consolidation(session_id, history)
    end
  end

  # Converts multimodal content (list of parts) to a plain string for storage/logging.
  # Discord CDN URLs are temporary, so we only persist the text portion.
  defp content_to_text(content) when is_binary(content), do: content

  defp content_to_text(parts) when is_list(parts) do
    Enum.map_join(parts, " ", fn
      %{"type" => "text", "text" => text} ->
        text

      %{"type" => "attachment_ref", "filename" => f, "size" => s} ->
        "[Arquivo: #{f} (#{s} bytes)]"

      _ ->
        ""
    end)
    |> String.trim()
  end

  # multimodal → sempre vai pro Executor
  defp is_just_chat?(input) when is_list(input), do: false

  defp is_just_chat?(input) do
    input = String.downcase(String.trim(input))

    greetings = [
      "oi",
      "ola",
      "olá",
      "bom dia",
      "boa tarde",
      "boa noite",
      "hello",
      "hi",
      "ping",
      "tudo bem"
    ]

    String.length(input) < 15 or input in greetings
  end

  defp quick_assistant_reply(session_pid, session_id, history, _current_input, model_override) do
    long_term_memory = if File.exists?("MEMORY.md"), do: File.read!("MEMORY.md"), else: ""

    assistant_prompt = """
    You are the Pincer Quick Assistant. Your function is to respond to greetings and simple questions BRIEFLY.

    ## RULES:
    1. If the message is "ping", respond only with "Pong!".
    2. Do not make up AI models. If the user asks about models, suggest using the /models command.
    3. Be friendly but extremely concise.

    ## LONG-TERM MEMORY (Narrative Context):
    #{long_term_memory}
    """

    assistant_history =
      [%{"role" => "system", "content" => assistant_prompt}] ++ Enum.take(history, -5)

    client_opts =
      if model_override,
        do: [provider: model_override.provider, model: model_override.model],
        else: []

    case Client.chat_completion(assistant_history, client_opts) do
      {:ok, %{"content" => response}} ->
        Storage.save_message(session_id, "assistant", response)
        send(session_pid, {:assistant_reply_finished, response})
        Pincer.PubSub.broadcast("session:#{session_id}", {:agent_response, response})

      {:error, reason} ->
        CoreTelemetry.emit_error(reason, %{scope: :quick_reply, component: :session_server})
        Logger.warning("[SESSION] Error in quick reply: #{inspect(reason)}")

        Pincer.PubSub.broadcast(
          "session:#{session_id}",
          {:agent_response, ErrorUX.friendly(reason, scope: :quick_reply)}
        )
    end
  end

  defp evaluate_blackboard_update(session_pid, session_id, history, model_override) do
    long_term_memory = if File.exists?("MEMORY.md"), do: File.read!("MEMORY.md"), else: ""

    system_prompt = """
    ## BLACKBOARD SYSTEM UPDATE
    Sub-agents have completed background tasks.

    Analyze the context below and decide IF the user DESERVES to be notified about this update.
    If the update is important (e.g. user-requested task completed or an important finding), respond with the message for the user.
    If it's just routine that the user doesn't care about, respond EXACTLY with the string 'IGNORE'.

    ## LONG-TERM MEMORY:
    #{long_term_memory}
    """

    eval_history = [%{"role" => "system", "content" => system_prompt}] ++ Enum.take(history, -5)

    client_opts =
      if model_override,
        do: [provider: model_override.provider, model: model_override.model],
        else: []

    case Client.chat_completion(eval_history, client_opts) do
      {:ok, %{"content" => response}} ->
        if String.upcase(String.trim(response)) != "IGNORE" do
          Storage.save_message(session_id, "assistant", response)
          send(session_pid, {:assistant_reply_finished, response})
          Pincer.PubSub.broadcast("session:#{session_id}", {:agent_response, response})
        end

      _ ->
        :ok
    end
  end

  @type session_id :: String.t()
  @type call_id :: String.t()
  @type provider :: atom()
  @type model :: String.t()

  @doc """
  Starts a new session server process.

  The session is registered in the `Pincer.Session.Registry` using the provided
  `session_id`, allowing subsequent calls to locate the process.

  ## Options

    * `:session_id` - Required. Unique identifier for the session.

  ## Examples

      {:ok, pid} = Pincer.Session.Server.start_link(session_id: "user_123")
      #=> {:ok, #PID<0.123.0>}

  ## Returns

    * `{:ok, pid}` - Successfully started
    * `{:error, {:already_started, pid}}` - Session already exists
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:session_id]))

  defp via_tuple(id), do: {:via, Registry, {Pincer.Session.Registry, id}}

  @doc """
  Processes user input and triggers appropriate response flow.

  The input is analyzed and routed to one of three paths:

  1. **Queued** - If session is already processing a request
  2. **Butler (Quick Reply)** - For simple greetings and short messages (< 15 chars)
  3. **Executor (Full Processing)** - For complex tasks requiring tool use

  Messages are persisted to storage and logged before processing.

  ## Examples

      # Simple greeting triggers quick reply
      {:ok, :butler_notified} = Pincer.Session.Server.process_input("user_123", "oi")

      # Complex request starts executor
      {:ok, :started} = Pincer.Session.Server.process_input("user_123", "Analyze my codebase")

      # Session busy - message queued
      {:ok, :queued} = Pincer.Session.Server.process_input("user_123", "Another request")

  ## Returns

    * `{:ok, :started}` - Executor started for complex task
    * `{:ok, :butler_notified}` - Quick assistant handling simple input
    * `{:ok, :queued}` - Session busy, message archived for later
  """
  @spec process_input(session_id(), String.t()) :: {:ok, :started | :butler_notified | :queued}
  def process_input(id, input), do: GenServer.call(via_tuple(id), {:process_input, input})

  @doc """
  Returns the current session state for debugging/monitoring.

  ## Examples

      {:ok, state} = Pincer.Session.Server.get_status("user_123")
      #=> {:ok, %{session_id: "user_123", status: :idle, history: [...], ...}}

  ## State Structure

    * `:session_id` - Unique identifier
    * `:status` - `:idle` or `:working`
    * `:history` - List of conversation messages
    * `:mode` - `:normal` or `:bootstrapping`
    * `:worker_pid` - PID of active Executor (nil when idle)
    * `:model_override` - Custom model configuration (nil for default)
    * `:last_blackboard_id` - Last processed blackboard message ID
  """
  @spec get_status(session_id()) :: {:ok, map()}
  def get_status(id), do: GenServer.call(via_tuple(id), :get_status)

  @doc """
  Overrides the default LLM model for this session.

  Takes effect immediately for subsequent requests.

  ## Examples

      :ok = Pincer.Session.Server.set_model("user_123", :anthropic, "claude-3-opus")
      :ok = Pincer.Session.Server.set_model("user_123", :openai, "gpt-4-turbo")

  ## Parameters

    * `id` - Session identifier
    * `provider` - Atom identifying the LLM provider (`:anthropic`, `:openai`, etc.)
    * `model` - Model identifier string

  ## Returns

    * `:ok` - Model override applied successfully
  """
  @spec set_model(session_id(), provider(), model()) :: :ok
  def set_model(id, provider, model),
    do: GenServer.call(via_tuple(id), {:set_model, provider, model})

  @doc """
  Approves a pending tool execution request.

  When an Executor encounters a tool requiring user approval, it sends a request
  to the session which broadcasts via PubSub. The UI calls this function to
  grant permission.

  ## Examples

      :ok = Pincer.Session.Server.approve_tool("user_123", "call_abc123")

  ## Parameters

    * `id` - Session identifier
    * `call_id` - Unique identifier from the tool approval request

  ## Returns

    * `:ok` - Approval sent to worker
    * `{:error, :no_active_worker}` - No executor running to receive approval
  """
  @spec approve_tool(session_id(), call_id()) :: :ok | {:error, :no_active_worker}
  def approve_tool(id, call_id), do: GenServer.call(via_tuple(id), {:approve_tool, call_id})

  @doc """
  Denies a pending tool execution request.

  The Executor will receive the denial and attempt alternative approaches
  or report the limitation to the user.

  ## Examples

      :ok = Pincer.Session.Server.deny_tool("user_123", "call_abc123")

  ## Parameters

    * `id` - Session identifier
    * `call_id` - Unique identifier from the tool approval request

  ## Returns

    * `:ok` - Denial sent to worker
    * `{:error, :no_active_worker}` - No executor running to receive denial
  """
  @spec deny_tool(session_id(), call_id()) :: :ok | {:error, :no_active_worker}
  def deny_tool(id, call_id), do: GenServer.call(via_tuple(id), {:deny_tool, call_id})

  defp get_system_prompt do
    identity = if File.exists?(@identity_file), do: File.read!(@identity_file), else: ""
    soul = if File.exists?(@soul_file), do: File.read!(@soul_file), else: ""
    user = if File.exists?(@user_file), do: File.read!(@user_file), else: ""

    orchestration_rules = """
    # ORCHESTRATION RULES (CRITICAL)
    You are a MANAGER AGENT. Your primary goal is to remain RESPONSIVE to the user.

    1. NEVER execute long-running tasks (loops, monitoring, heavy processing) yourself.
    2. USE the `dispatch_agent` tool to delegate these tasks to Sub-Agents.
    3. If a task involves waiting or watching, YOU MUST DELEGATE IT.
    4. You will receive updates from Sub-Agents via the Blackboard (SYSTEM UPDATE messages).
    5. When you receive a SYSTEM UPDATE, decide if the user needs to know. If yes, inform them concisely.
    6. FORMATTING: Use standard Markdown for formatting your response (bold, italics, code blocks).
    """

    "#{identity}\n\n## SOUL:\n#{soul}\n\n## ORCHESTRATION:\n#{orchestration_rules}\n\n## USER:\n#{user}"
  end
end
