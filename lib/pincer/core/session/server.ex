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
  alias Pincer.Core.Executor
  alias Pincer.Core.SubAgentProgress
  alias Pincer.Infra.PubSub
  alias Pincer.Core.Orchestration.Blackboard

  @identity_file "IDENTITY.md"
  @soul_file "SOUL.md"
  @user_file "USER.md"
  @bootstrap_file "BOOTSTRAP.md"

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace_path = "workspaces/#{session_id}"
    File.mkdir_p!(workspace_path)

    # 1. Recupera mensagens persistidas
    persisted = Storage.get_messages(session_id)

    # 2. Inscrição em tópicos PubSub
    PubSub.subscribe("session:#{session_id}")
    PubSub.subscribe("system:updates")

    # 3. Estado inicial
    state = %{
      mode: :normal,
      session_id: session_id,
      workspace_path: workspace_path,
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
      debounce_timer: nil
    }

    # 4. Carrega histórico final
    history =
      if Enum.empty?(persisted),
        do: [%{"role" => "system", "content" => get_system_prompt(state)}],
        else: [%{"role" => "system", "content" => get_system_prompt(state)} | persisted]

    state = %{state | history: history}

    # 5. Catch-up assíncrono para não travar o boot
    send(self(), :recovery_catch_up)

    # 6. Bootstrap Handshake (se for a primeira vez ou BOOTSTRAP.md existir)
    if Enum.empty?(persisted) and File.exists?(@bootstrap_file) do
      send(self(), :trigger_bootstrap)
    end

    # 7. Heartbeat para manter Blackboard atualizado
    Process.send_after(self(), :heartbeat, 5000)

    {:ok, state}
  end

  # --- Callbacks ---

  @impl true
  def handle_info(:recovery_catch_up, state) do
    Logger.info("[SESSION] #{state.session_id} Maestro performing recovery catch-up...")

    # Lê tudo do Blackboard que aconteceu desde a última vez que este agente esteve vivo
    case Blackboard.fetch_new(state.last_blackboard_id) do
      {[], _} ->
        {:noreply, state}

      {messages, new_last_id} ->
        Logger.info(
          "[SESSION] #{state.session_id} Caught up with #{length(messages)} missed messages."
        )

        # Durante o boot, processamos mas NÃO notificamos canais externos (silencioso)
        process_blackboard_messages(messages, new_last_id, state, broadcast?: false)
    end
  end

  @impl true
  def handle_info(:trigger_bootstrap, state) do
    # Deixamos o próprio LLM decidir como se apresentar baseado no BOOTSTRAP.md
    # mas forçamos um início se o histórico estiver vazio
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

    case Blackboard.fetch_new(state.last_blackboard_id) do
      {[], _} ->
        {:noreply, state}

      {messages, new_last_id} ->
        process_blackboard_messages(messages, new_last_id, state, broadcast?: true)
    end
  end

  @impl true
  def handle_info({:assistant_reply_finished, response}, state) do
    new_history = state.history ++ [%{"role" => "assistant", "content" => response}]
    {:noreply, %{state | history: new_history}}
  end

  @impl true
  def handle_info({:executor_finished, final_history, response, usage}, state) do
    usage = usage || %{}
    
    # Normaliza chaves do usage (podem vir como strings ou átomos dependendo do provedor/mock)
    prompt_tokens = usage["prompt_tokens"] || usage[:prompt_tokens] || 0
    completion_tokens = usage["completion_tokens"] || usage[:completion_tokens] || 0

    new_totals = %{
      "prompt_tokens" => state.token_usage_total["prompt_tokens"] + prompt_tokens,
      "completion_tokens" => state.token_usage_total["completion_tokens"] + completion_tokens
    }

    publish(state.session_id, {:agent_response, response, usage})
    {:noreply, %{state | history: final_history, status: :idle, worker_pid: nil, token_usage_total: new_totals}}
  end

  @impl true
  def handle_info({:agent_stream_token, token}, state) do
    publish(state.session_id, {:agent_partial, token})
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_response, _content, _usage}, state) do
    # Ignora a cópia do broadcast que volta via PubSub, 
    # já que o histórico é atualizado via :assistant_reply_finished ou :executor_finished
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
              publish(state.session_id, {:agent_response, "🚀 Projeto iniciado com ID: `#{id}`"})

            _ ->
              publish(state.session_id, {:agent_response, "✅ Comando #{cmd} executado."})
          end
        end)

        {:noreply, state}

      :error ->
        # Lógica padrão de chat (Butler ou Executor)
        case process_standard_input(combined_input, state) do
          {:reply, _reply, new_state} -> {:noreply, new_state}
          _ -> {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:agent_status, _status}, state) do
    # Ignora atualizações de status (ex: "Digitando...") no servidor de sessão
    {:noreply, state}
  end

  @impl true
  def handle_info({:system_update_prompt}, state) do
    Logger.info("[SESSION] #{state.session_id} hot-swapping system prompt...")
    
    new_history = case state.history do
      [%{"role" => "system"} | rest] ->
        [%{"role" => "system", "content" => get_system_prompt(state)} | rest]
      other ->
        other
    end

    {:noreply, %{state | history: new_history}}
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

    # Notifica o usuário sobre o progresso dos operários (apenas se broadcast for true)
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

            "📋 **Plano de Projeto Sugerido (#{msg.project_id})**:\n#{plan}\n\nPara prosseguir, use:\n`/project approve #{msg.project_id}`\nOu modifique com:\n`/project modify #{msg.project_id} <novas tarefas>`"

          String.contains?(msg.content, "ERROR_DIAGNOSTIC:") ->
            reason = String.replace(msg.content, "ERROR_DIAGNOSTIC: ", "")

            "❌ **FALHA CRÍTICA NO PROJETO (#{msg.project_id})**\nO agente esgotou as tentativas de execução.\n\n**Motivo Detectado:**\n`#{reason}`\n\nVocê pode:\n1. `/project resume #{msg.project_id}` (Tentar novamente)\n2. `/project modify #{msg.project_id} <plano>` (Corrigir a rota)\n3. `/project stop #{msg.project_id}`"

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

    # Se estiver ocioso e algo importante aconteceu, o Maestro avalia se deve falar algo
    # Apenas se broadcast for true (evita que o bot comece a falar sozinho durante o boot)
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

    # 1. Limpa SQLite
    Pincer.Ports.Storage.delete_messages(state.session_id)

    # 2. Reseta RAM (mantém apenas o system prompt inicial)
    new_history = [%{"role" => "system", "content" => get_system_prompt(state)}]

    # 3. Dispara Bootstrap novamente
    send(self(), :trigger_bootstrap)

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

  @impl true
  def handle_call({:process_input, input}, _from, state) do
    # Cancel previous timer if exists
    if state.debounce_timer, do: Process.cancel_timer(state.debounce_timer)

    new_buffer = state.input_buffer ++ [input]
    # Wait 1200ms for more chunks before flushing (safer for high latency)
    new_timer = Process.send_after(self(), :flush_input, 1200)

    {:reply, {:ok, :buffered}, %{state | input_buffer: new_buffer, debounce_timer: new_timer}}
  end

  # --- Boilerplate & Standard Flow ---

  defp process_standard_input(input, state) do
    text_for_storage = content_to_text(input)
    Storage.save_message(state.session_id, "user", text_for_storage)
    Pincer.Core.Session.Logger.log(state.session_id, "user", text_for_storage)

    user_msg = %{"role" => "user", "content" => input}
    new_history = state.history ++ [user_msg]

    if is_just_chat?(input) do
      Task.start(fn ->
        quick_assistant_reply(self(), state.session_id, new_history, input, state.model_override)
      end)

      {:reply, {:ok, :butler_notified}, %{state | history: new_history}}
    else
      executor_opts = [
        model_override: state.model_override,
        workspace_path: state.workspace_path
      ]
      {:ok, pid} = Executor.start(self(), state.session_id, new_history, executor_opts)

      {:reply, {:ok, :started},
       %{state | history: new_history, worker_pid: pid, status: :working}}
    end
  end

  defp publish(session_id, event) do
    PubSub.broadcast("session:#{session_id}", event)
  end

  # (Restante das funções auxiliares mantidas para compatibilidade...)
  # get_system_prompt, content_to_text, is_just_chat?, quick_assistant_reply, evaluate_blackboard_update, etc.

  defp get_system_prompt(state) do
    workspace = state.workspace_path
    
    # Check if local files exist in workspace, fallback to globals
    identity = read_config_file(Path.join(workspace, @identity_file), @identity_file)
    soul = read_config_file(Path.join(workspace, @soul_file), @soul_file)
    user = read_config_file(Path.join(workspace, @user_file), @user_file)
    bootstrap = if File.exists?(@bootstrap_file), do: File.read!(@bootstrap_file), else: ""

    prompt = """
    #{if bootstrap != "", do: "!!! BOOTSTRAP MODE ACTIVE !!!\n#{bootstrap}\n", else: ""}

    # YOUR CURRENT IDENTITY
    #{identity}

    ## SOUL:
    #{soul}

    ## USER:
    #{user}
    """

    String.trim(prompt)
  end

  defp read_config_file(workspace_path, global_path) do
    cond do
      File.exists?(workspace_path) -> File.read!(workspace_path)
      File.exists?(global_path) -> File.read!(global_path)
      true -> ""
    end
  end

  defp content_to_text(c) when is_binary(c), do: c

  defp content_to_text(p) when is_list(p),
    do:
      Enum.map_join(p, " ", fn
        %{"text" => t} -> t
        _ -> ""
      end)

  defp is_just_chat?(input) when is_list(input), do: false

  defp is_just_chat?(input) do
    String.length(input) < 15 or String.downcase(input) in ["oi", "ola", "ping"]
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
    # Simula avaliação se o usuário deve ser interrompido
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
    GenServer.call(via_tuple(id), {:set_model, provider, model})
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
