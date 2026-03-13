defmodule Pincer.Core.Session.Server do
  @moduledoc """
  Core session GenServer implementing the Pincer Brain (The Maestro).

  The Maestro orchestrates conversation, manages sub-agents via the Blackboard,
  and delegates long-running projects to dedicated Project.Server processes.
  It is designed to be 100% responsive and resilient to hot-reloads.
  """
  use GenServer, restart: :transient
  require Logger

  alias Pincer.Ports.LLM
  alias Pincer.Ports.Storage
  alias Pincer.Core.AgentPaths
  alias Pincer.Core.ErrorUX
  alias Pincer.Core.Executor
  alias Pincer.Core.SubAgentProgress
  alias Pincer.Infra.PubSub
  alias Pincer.Core.Orchestration.Blackboard

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    root_agent_id = Keyword.get(opts, :root_agent_id, session_id)
    Logger.metadata(session_id: session_id)
    workspace_path = Keyword.get(opts, :workspace_path, AgentPaths.workspace_root(root_agent_id))
    bootstrap? = Keyword.get(opts, :bootstrap?, true)
    principal_ref = Keyword.get(opts, :principal_ref)
    conversation_ref = Keyword.get(opts, :conversation_ref)
    blackboard_scope = Keyword.get(opts, :blackboard_scope, root_agent_id)
    llm_client = Keyword.get(opts, :llm_client)

    ensure_opts = [bootstrap?: bootstrap?]

    AgentPaths.ensure_workspace!(workspace_path, ensure_opts)

    # 1. Retrieve persisted messages
    persisted = Storage.get_messages(session_id)

    # 2. Subscribe to PubSub topics
    PubSub.subscribe("session:#{session_id}")
    PubSub.subscribe("system:updates")

    # 3. Initial state
    state = %{
      mode: :normal,
      session_id: session_id,
      root_agent_id: root_agent_id,
      principal_ref: principal_ref,
      conversation_ref: conversation_ref,
      workspace_path: workspace_path,
      blackboard_scope: blackboard_scope,
      history: [],
      status: :idle,
      worker_pid: nil,
      last_blackboard_id: 0,
      subagent_progress_tracker: %{},
      model_override: nil,
      thinking_level: nil,
      reasoning_visible: false,
      verbose: false,
      usage_display: "off",
      token_usage_total: %{"prompt_tokens" => 0, "completion_tokens" => 0},
      input_buffer: [],
      debounce_timer: nil,
      llm_client: llm_client,
      watcher_pid: nil
    }

    # 4. Start Graph Watcher for this workspace
    state =
      if Application.get_env(:pincer, :enable_graph_watcher, true) do
        case Pincer.Core.Graph.Watcher.start_link(workspace_root: workspace_path) do
          {:ok, pid} -> %{state | watcher_pid: pid}
          _ -> state
        end
      else
        state
      end

    # 5. Build final history
    history =
      if Enum.empty?(persisted),
        do: [%{"role" => "system", "content" => get_system_prompt(state)}],
        else: [%{"role" => "system", "content" => get_system_prompt(state)} | persisted]

    state = %{state | history: history}

    # 5. Asynchronous catch-up to avoid blocking boot
    send(self(), :recovery_catch_up)

    # 6. Bootstrap Handshake (first-time session or BOOTSTRAP.md still active)
    if Enum.empty?(persisted) and bootstrap_active?(workspace_path) do
      send(self(), :trigger_bootstrap)
    end

    # 7. Heartbeat for periodic Blackboard polling
    Process.send_after(self(), :heartbeat, 5000)

    {:ok, state}
  end

  # --- Callbacks ---

  @impl true
  def handle_info(:recovery_catch_up, state) do
    Logger.info("[SESSION] #{state.session_id} Maestro performing recovery catch-up...")

    # Fetch asynchronously so the GenServer stays responsive to calls during the O(n) journal scan.
    parent = self()
    since_id = state.last_blackboard_id
    scope = state.blackboard_scope

    Task.start(fn ->
      case Blackboard.fetch_new(since_id, scope: scope) do
        {[], _} -> :ok
        {messages, new_last_id} -> send(parent, {:recovery_catch_up_done, messages, new_last_id})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:recovery_catch_up_done, messages, new_last_id}, state) do
    Logger.info(
      "[SESSION] #{state.session_id} Caught up with #{length(messages)} missed messages."
    )

    # During boot, process silently without broadcasting to external channels
    process_blackboard_messages(messages, new_last_id, state, broadcast?: false)
  end

  @impl true
  def handle_info(:trigger_bootstrap, state) do
    # Let the LLM decide how to introduce itself based on BOOTSTRAP.md;
    # force a start if the history is empty
    history_with_prompt = [%{"role" => "system", "content" => get_system_prompt(state)}]

    Task.start(fn ->
      evaluate_blackboard_update(
        self(),
        state.session_id,
        history_with_prompt,
        state.model_override
      )
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, 10000)

    case Blackboard.fetch_new(state.last_blackboard_id, scope: state.blackboard_scope) do
      {[], _} ->
        {:noreply, state}

      {messages, new_last_id} ->
        process_blackboard_messages(messages, new_last_id, state, broadcast?: true)
    end
  end

  @impl true
  def handle_info({:assistant_reply_finished, response}, state) do
    persist_assistant_response(state.session_id, response)
    new_history = state.history ++ [%{"role" => "assistant", "content" => response}]
    {:noreply, %{state | history: new_history}}
  end

  @impl true
  def handle_info({:executor_finished, final_history, response, usage}, state) do
    usage = usage || %{}
    persist_assistant_response(state.session_id, response)

    # Normalize usage keys (may arrive as strings or atoms depending on provider/mock)
    prompt_tokens = usage["prompt_tokens"] || usage[:prompt_tokens] || 0
    completion_tokens = usage["completion_tokens"] || usage[:completion_tokens] || 0

    new_totals = %{
      "prompt_tokens" => state.token_usage_total["prompt_tokens"] + prompt_tokens,
      "completion_tokens" => state.token_usage_total["completion_tokens"] + completion_tokens
    }

    publish(state.session_id, {:agent_response, response, usage})

    {:noreply,
     %{
       state
       | history: final_history,
         status: :idle,
         worker_pid: nil,
         token_usage_total: new_totals
     }}
  end

  @impl true
  def handle_info({:agent_stream_token, token}, state) do
    publish(state.session_id, {:agent_partial, token})
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_partial, _token}, state) do
    # Ignore self-broadcast tokens (intended for external channels)
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_status, _status}, state) do
    # Ignore self-broadcast status updates
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_response, _content, _usage}, state) do
    # Ignore self-broadcast response (history handled via executor_finished)
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_response, _content}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush_input, state) do
    combined_input =
      state.input_buffer
      |> Enum.map(&content_to_text/1)
      |> Enum.join("\n")

    # Reset buffer and timer
    state = %{state | input_buffer: [], debounce_timer: nil}

    case Pincer.Core.ProjectRouter.parse(combined_input) do
      {:ok, cmd, args} ->
        Task.start(fn ->
          case Pincer.Core.ProjectRouter.handle_command(cmd, args, state.session_id) do
            {:ok, id} ->
              publish(state.session_id, {:agent_response, "🚀 Project started with ID: `#{id}`"})

            _ ->
              publish(state.session_id, {:agent_response, "✅ Command #{cmd} executed."})
          end
        end)

        {:noreply, state}

      :error ->
        # Standard chat logic (Butler or Executor)
        case process_standard_input(combined_input, state) do
          {:reply, _reply, new_state} -> {:noreply, new_state}
          _ -> {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:system_update_prompt}, state) do
    Logger.info("[SESSION] #{state.session_id} hot-swapping system prompt...")

    new_history =
      case state.history do
        [%{"role" => "system"} | rest] ->
          [%{"role" => "system", "content" => get_system_prompt(state)} | rest]

        other ->
          other
      end

    {:noreply, %{state | history: new_history}}
  end

  @impl true
  def handle_info({:llm_runtime_status, %{kind: :failover} = meta}, state) do
    if state.verbose do
      msg = "🔄 **Failover**: Swapping to `#{meta.provider}/#{meta.model}` due to `#{meta.reason}`"
      publish(state.session_id, {:agent_response, msg})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:llm_runtime_status, _meta}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:executor_failed, reason}, state) do
    Logger.error("[SESSION] #{state.session_id} Executor failed: #{inspect(reason)}")

    error_msg = "❌ #{ErrorUX.friendly(reason, scope: :executor)}"

    publish(state.session_id, {:agent_response, error_msg})
    {:noreply, %{state | status: :idle, worker_pid: nil}}
  end

  @impl true
  def handle_info({:sme_status, _sme_name, msg}, state) do
    publish(state.session_id, {:agent_status, msg})
    {:noreply, state}
  end

  @impl true
  def handle_info({:sme_tool_use, tools}, state) do
    publish(state.session_id, {:agent_status, "🛠️ Usando ferramentas: #{tools}"})
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[SESSION] #{state.session_id} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Maestro Logic: Processing Blackboard ---

  defp process_blackboard_messages(messages, new_last_id, state, opts) do
    broadcast? = Keyword.get(opts, :broadcast?, true)

    {progress_notifications, progress_tracker, needs_review?} =
      SubAgentProgress.notifications(messages, state.subagent_progress_tracker)

    # Notify the user about sub-agent progress (only when broadcasting is enabled)
    if broadcast? do
      Enum.each(progress_notifications, fn message ->
        publish(state.session_id, {:agent_status, message})
      end)
    end

    updates =
      messages
      |> Enum.map(fn msg ->
        cond do
          String.contains?(msg.content, "PLAN_GENERATED:") ->
            plan = String.replace(msg.content, "PLAN_GENERATED:\n", "")

            "📋 **Suggested Project Plan (#{msg.project_id})**:\n#{plan}\n\nTo proceed, use:\n`/project approve #{msg.project_id}`\nOr modify with:\n`/project modify #{msg.project_id} <new tasks>`"

          String.contains?(msg.content, "ERROR_DIAGNOSTIC:") ->
            reason = String.replace(msg.content, "ERROR_DIAGNOSTIC: ", "")

            "❌ **CRITICAL PROJECT FAILURE (#{msg.project_id})**\nThe agent exhausted all execution attempts.\n\n**Detected Reason:**\n`#{reason}`\n\nYou can:\n1. `/project resume #{msg.project_id}` (Retry)\n2. `/project modify #{msg.project_id} <plan>` (Change course)\n3. `/project stop #{msg.project_id}`"

          true ->
            "[#{msg.project_id || "GLOBAL"}]: #{msg.content}"
        end
      end)
      |> Enum.join("\n\n")

    system_msg = %{
      "role" => "system",
      "content" => "SYSTEM UPDATE (Blackboard):\n#{updates}"
    }

    new_history = state.history ++ [system_msg]

    # If idle and something important happened, the Maestro evaluates whether to speak up
    # Only when broadcasting (prevents the bot from talking unprompted during boot)
    if broadcast? and state.status == :idle and needs_review? do
      Task.start(fn ->
        evaluate_blackboard_update(self(), state.session_id, new_history, state.model_override)
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

  # --- Input Handling ---

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    Logger.info("[SESSION] #{state.session_id} resetting history...")

    history = state.history
    session_id = state.session_id

    Task.start(fn ->
      message_count = history |> Enum.reject(&(&1["role"] == "system")) |> length()
      reset_at = DateTime.utc_now()

      snapshot_content =
        "session_id=#{session_id} message_count=#{message_count} reset_at=#{DateTime.to_iso8601(reset_at)}"

      case Pincer.Core.Memory.record_session(snapshot_content, session_id: session_id) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.info("[SESSION] reset snapshot skipped: #{inspect(reason)}")
      end
    end)

    # 1. Clear persisted transcripts in Postgres
    Pincer.Ports.Storage.delete_messages(state.session_id)

    # 2. Reset RAM (keep only the initial system prompt)
    new_history = [%{"role" => "system", "content" => get_system_prompt(state)}]

    # 3. Re-trigger Bootstrap only if identity files do not exist yet
    if bootstrap_active?(state.workspace_path) do
      send(self(), :trigger_bootstrap)
    end

    {:reply, :ok, %{state | history: new_history, status: :idle, worker_pid: nil}}
  end

  @impl true
  def handle_call({:set_model, provider, model}, _from, state) do
    Logger.info("[SESSION] #{state.session_id} switching model to #{provider}:#{model}")

    if is_pid(state.worker_pid) and Process.alive?(state.worker_pid) do
      send(state.worker_pid, {:model_changed, provider, model})
    end

    new_state = %{state | model_override: %{provider: provider, model: model}}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_thinking, level}, _from, state) do
    {:reply, :ok, %{state | thinking_level: level}}
  end

  @impl true
  def handle_call({:set_reasoning_visible, visible}, _from, state) do
    {:reply, :ok, %{state | reasoning_visible: visible}}
  end

  @impl true
  def handle_call({:set_verbose, verbose}, _from, state) do
    {:reply, :ok, %{state | verbose: verbose}}
  end

  @impl true
  def handle_call({:set_usage, level}, _from, state) do
    {:reply, :ok, %{state | usage_display: level}}
  end

  alias Pincer.Core.Structs.IncomingMessage

  @impl true
  def handle_call({:process_input, %IncomingMessage{} = input}, _from, state) do
    # Cancel previous timer if exists
    if state.debounce_timer, do: Process.cancel_timer(state.debounce_timer)

    # For buffering, we collect the text from the incoming message
    new_buffer = state.input_buffer ++ [input.text]
    # Wait 1200ms for more chunks before flushing (safer for high latency)
    new_timer = Process.send_after(self(), :flush_input, 1200)

    {:reply, {:ok, :buffered}, %{state | input_buffer: new_buffer, debounce_timer: new_timer}}
  end

  def handle_call({:process_input, input}, from, state) when is_binary(input) do
    # Legacy support: convert string to IncomingMessage
    msg = IncomingMessage.new(state.session_id, input)
    handle_call({:process_input, msg}, from, state)
  end

  # --- Boilerplate & Standard Flow ---

  defp process_standard_input(input, state) do
    # input can be binary (from legacy) or IncomingMessage (from new flow)
    text_for_storage = content_to_text(input)
    Storage.save_message(state.session_id, "user", text_for_storage)

    Pincer.Core.Session.Logger.log(
      state.session_id,
      "user",
      text_for_storage,
      workspace_path: state.workspace_path
    )

    # Map to LLM history format
    user_msg = map_input_to_history(input)
    new_history = state.history ++ [user_msg]

    if is_just_chat?(text_for_storage) do
      Task.start(fn ->
        quick_assistant_reply(
          self(),
          state.session_id,
          new_history,
          text_for_storage,
          state.model_override
        )
      end)

      {:reply, {:ok, :butler_notified}, %{state | history: new_history}}
    else
      model_override_with_thinking =
        if state.thinking_level != nil and is_map(state.model_override) do
          Map.put(state.model_override, :thinking_level, state.thinking_level)
        else
          state.model_override
        end

      executor_opts =
        [model_override: model_override_with_thinking, workspace_path: state.workspace_path]
        |> then(fn opts ->
          if state.llm_client, do: Keyword.put(opts, :llm_client, state.llm_client), else: opts
        end)

      {:ok, pid} = Executor.start(self(), state.session_id, new_history, executor_opts)

      {:reply, {:ok, :started},
       %{state | history: new_history, worker_pid: pid, status: :working}}
    end
  end

  defp map_input_to_history(%IncomingMessage{text: text, attachments: []}),
    do: %{"role" => "user", "content" => text}

  defp map_input_to_history(%IncomingMessage{text: text, attachments: atts}) do
    content =
      [%{"type" => "text", "text" => text}] ++
        Enum.map(atts, fn a -> %{"type" => "attachment", "attachment" => a} end)

    %{"role" => "user", "content" => content}
  end

  defp map_input_to_history(input) when is_binary(input),
    do: %{"role" => "user", "content" => input}

  defp publish(session_id, event) do
    PubSub.broadcast("session:#{session_id}", event)
  end

  # (Remaining helper functions kept for compatibility...)
  # get_system_prompt, content_to_text, is_just_chat?, quick_assistant_reply, evaluate_blackboard_update, etc.

  defp get_system_prompt(state) do
    workspace = state.workspace_path

    identity = AgentPaths.read_file(AgentPaths.identity_path(workspace))
    soul = AgentPaths.read_file(AgentPaths.soul_path(workspace))
    user = AgentPaths.read_file(AgentPaths.user_path(workspace))

    bootstrap =
      if bootstrap_active?(workspace) do
        AgentPaths.read_file(AgentPaths.bootstrap_path(workspace))
      else
        ""
      end

    prompt = """
    #{if bootstrap != "", do: "!!! BOOTSTRAP MODE ACTIVE !!!\n#{bootstrap}\n", else: ""}

    # YOUR CURRENT IDENTITY
    #{identity}

    ## SOUL:
    #{soul}

    ## USER:
    #{user}

    ## CAPABILITIES & TOOLS:
    You are a technical agent with access to multiple tools through the Model Context Protocol (MCP) and native Elixir integrations.
    You can read and write files, execute shell commands, manage projects, and more.
    Never claim you don't have tools; if a task requires technical action, you must use the available tools to perform it.

    **CRITICAL RULE - ALWAYS RESPOND**: After using any tool, you MUST provide a final textual response to the user summarizing what you did and showing relevant results. NEVER finish with an empty message if you performed actions.

    **Example of correct behavior:**
    - User asks: "Leia o arquivo config.txt"
    - You use: file_system tool to read config.txt
    - You MUST respond: "✅ Li o arquivo config.txt. Ele contém: [conteúdo resumido]"

    **WRONG behavior (NEVER do this):**
    - Use file_system tool
    - Return empty response ❌

    **CHAT POLICY**:
    - To talk to the current user in this session, just write plain text normally.
    - NEVER use `channel_actions` to talk to the user you are currently chatting with. That tool is only for sending messages to DIFFERENT channels or users.
    - **NEVER** return empty content after using tools. Always explain what you did.
    """

    prompt = String.trim(prompt)
    Logger.debug("[SESSION] GENERATED SYSTEM PROMPT:\n#{prompt}")
    prompt
  end

  @doc false
  def bootstrap_active?(workspace_path, opts \\ []) when is_binary(workspace_path) do
    # Even if the BOOTSTRAP.md file exists, if we already have IDENTITY and SOUL,
    # it means the ritual is done.
    has_identity? = File.exists?(AgentPaths.identity_path(workspace_path))
    has_soul? = File.exists?(AgentPaths.soul_path(workspace_path))

    if has_identity? and has_soul? do
      false
    else
      AgentPaths.bootstrap_active?(workspace_path, opts)
    end
  end

  defp persist_assistant_response(_session_id, response) when not is_binary(response), do: :ok

  defp persist_assistant_response(session_id, response) do
    trimmed = String.trim(response)

    if trimmed != "" do
      Storage.save_message(session_id, "assistant", trimmed)
    end

    :ok
  end

  defp content_to_text(%IncomingMessage{text: text}), do: text
  defp content_to_text(c) when is_binary(c), do: c

  defp content_to_text(p) when is_list(p),
    do:
      Enum.map_join(p, " ", fn
        %{"text" => t} -> t
        _ -> ""
      end)

  defp is_just_chat?(input) when is_list(input), do: false

  defp is_just_chat?(input) do
    normalized = String.downcase(String.trim(input))

    # Action verbs or technical commands should not be treated as "just chat"
    technical_intent? =
      String.match?(
        normalized,
        ~r/^(ls|cat|read|write|git|mix|python|node|npx|sh|bash|exec|run|make|grep|find|mkdir|rm|cp|mv|project|plan|create|edit|save)\b/
      )

    cond do
      technical_intent? -> false
      String.length(input) < 8 -> true
      normalized in ["oi", "ola", "ping", "hello", "hi", "hey"] -> true
      true -> false
    end
  end

  defp quick_assistant_reply(pid, sid, hist, _in, mo) do
    case LLM.chat_completion(hist, if(mo, do: [provider: mo.provider, model: mo.model], else: [])) do
      {:ok, %{"content" => resp}, usage} ->
        send(pid, {:assistant_reply_finished, resp})
        PubSub.broadcast("session:#{sid}", {:agent_response, resp, usage})

      _ ->
        :ok
    end
  end

  defp evaluate_blackboard_update(pid, sid, hist, mo) do
    # Evaluate whether the user should be interrupted with new information
    case LLM.chat_completion(hist, if(mo, do: [provider: mo.provider, model: mo.model], else: [])) do
      {:ok, %{"content" => resp}, usage} ->
        if String.upcase(resp) != "IGNORE" do
          send(pid, {:assistant_reply_finished, resp})
          PubSub.broadcast("session:#{sid}", {:agent_response, resp, usage})
        end

      _ ->
        :ok
    end
  end

  # --- Boilerplate API ---
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:session_id]))

  defp via_tuple(id), do: {:via, Registry, {Pincer.Core.Session.Registry, id}}
  def process_input(id, input), do: GenServer.call(via_tuple(id), {:process_input, input})
  def get_status(id), do: GenServer.call(via_tuple(id), :get_status)

  def reset(id) do
    GenServer.call(via_tuple(id), :reset)
  end

  def set_model(id, provider, model) do
    GenServer.call(via_tuple(id), {:set_model, provider, model}, 15_000)
  end

  def set_thinking(id, level),
    do: GenServer.call(via_tuple(id), {:set_thinking, level})

  def set_reasoning_visible(id, visible),
    do: GenServer.call(via_tuple(id), {:set_reasoning_visible, visible})

  def set_verbose(id, verbose),
    do: GenServer.call(via_tuple(id), {:set_verbose, verbose})

  def set_usage(id, level),
    do: GenServer.call(via_tuple(id), {:set_usage, level})
end
