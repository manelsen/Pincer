defmodule Pincer.Session.Server do
  @moduledoc """
  Core session GenServer implementing the Pincer Brain (The Maestro).
  
  The Maestro orchestrates conversation, manages sub-agents via the Blackboard,
  and delegates long-running projects to dedicated Project.Server processes.
  It is designed to be 100% responsive and resilient to hot-reloads.
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
  alias Pincer.Orchestration.Blackboard

  @identity_file "IDENTITY.md"
  @soul_file "SOUL.md"
  @user_file "USER.md"

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    # 1. Recupera mensagens persistidas
    persisted = Storage.get_messages(session_id)
    history = if Enum.empty?(persisted),
      do: [%{"role" => "system", "content" => get_system_prompt()}],
      else: [%{"role" => "system", "content" => get_system_prompt()} | persisted]

    # 2. Inscrição em tópicos PubSub
    PubSub.subscribe("session:#{session_id}")
    PubSub.subscribe("system:updates")

    # 3. Estado inicial
    state = %{
      mode: :normal,
      session_id: session_id,
      history: history,
      status: :idle,
      worker_pid: nil,
      last_blackboard_id: 0,
      subagent_progress_tracker: %{},
      model_override: nil
    }

    # 4. Catch-up assíncrono para não travar o boot
    send(self(), :recovery_catch_up)
    
    # 5. Heartbeat para manter Blackboard atualizado
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
        Logger.info("[SESSION] #{state.session_id} Caught up with #{length(messages)} missed messages.")
        # Processa as mensagens como se tivessem acabado de chegar
        process_blackboard_messages(messages, new_last_id, state)
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, 10000)
    
    case Blackboard.fetch_new(state.last_blackboard_id) do
      {[], _} -> {:noreply, state}
      {messages, new_last_id} ->
        process_blackboard_messages(messages, new_last_id, state)
    end
  end

  # --- Maestro Logic: Processing Blackboard ---

  defp process_blackboard_messages(messages, new_last_id, state) do
    {progress_notifications, progress_tracker, needs_review?} =
      SubAgentProgress.notifications(messages, state.subagent_progress_tracker)

    # Notifica o usuário sobre o progresso dos operários
    Enum.each(progress_notifications, fn message ->
      publish(state.session_id, {:agent_status, message})
    end)

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
    if state.status == :idle and needs_review? do
      Task.start(fn ->
        evaluate_blackboard_update(self(), state.session_id, new_history, state.model_override)
      end)
    end

    {:noreply, %{state | history: new_history, last_blackboard_id: new_last_id, subagent_progress_tracker: progress_tracker}}
  end

  # --- Input Handling ---

  @impl true
  def handle_call({:process_input, input}, _from, state) do
    text = content_to_text(input)
    
    case Pincer.Core.ProjectRouter.parse(text) do
      {:ok, cmd, args} ->
        Task.start(fn -> 
          case Pincer.Core.ProjectRouter.handle_command(cmd, args, state.session_id) do
            {:ok, id} -> 
              publish(state.session_id, {:agent_response, "🚀 Projeto iniciado com ID: `#{id}`"})
            _ -> 
              publish(state.session_id, {:agent_response, "✅ Comando #{cmd} executado."})
          end
        end)
        {:reply, {:ok, :started}, state}

      :error ->
        # Lógica padrão de chat (Butler ou Executor)
        process_standard_input(input, state)
    end
  end

  # --- Boilerplate & Standard Flow ---

  defp process_standard_input(input, state) do
    text_for_storage = content_to_text(input)
    Storage.save_message(state.session_id, "user", text_for_storage)
    Pincer.Session.Logger.log(state.session_id, "user", text_for_storage)
    
    user_msg = %{"role" => "user", "content" => input}
    new_history = state.history ++ [user_msg]

    if is_just_chat?(input) do
      Task.start(fn -> quick_assistant_reply(self(), state.session_id, new_history, input, state.model_override) end)
      {:reply, {:ok, :butler_notified}, %{state | history: new_history}}
    else
      executor_opts = [model_override: state.model_override]
      {:ok, pid} = Executor.start(self(), state.session_id, new_history, executor_opts)
      {:reply, {:ok, :started}, %{state | history: new_history, worker_pid: pid, status: :working}}
    end
  end

  defp publish(session_id, event) do
    PubSub.broadcast("session:#{session_id}", event)
  end

  # (Restante das funções auxiliares mantidas para compatibilidade...)
  # get_system_prompt, content_to_text, is_just_chat?, quick_assistant_reply, evaluate_blackboard_update, etc.

  defp get_system_prompt do
    identity = if File.exists?(@identity_file), do: File.read!(@identity_file), else: ""
    soul = if File.exists?(@soul_file), do: File.read!(@soul_file), else: ""
    user = if File.exists?(@user_file), do: File.read!(@user_file), else: ""

    "#{identity}\n\n## SOUL:\n#{soul}\n\n## USER:\n#{user}"
  end

  defp content_to_text(c) when is_binary(c), do: c
  defp content_to_text(p) when is_list(p), do: Enum.map_join(p, " ", fn %{"text" => t} -> t; _ -> "" end)

  defp is_just_chat?(input) when is_list(input), do: false
  defp is_just_chat?(input) do
    String.length(input) < 15 or String.downcase(input) in ["oi", "ola", "ping"]
  end

  defp quick_assistant_reply(pid, sid, hist, _in, mo) do
    case Client.chat_completion(hist, if(mo, do: [provider: mo.provider, model: mo.model], else: [])) do
      {:ok, %{"content" => resp}} -> 
        send(pid, {:assistant_reply_finished, resp})
        PubSub.broadcast("session:#{sid}", {:agent_response, resp})
      _ -> :ok
    end
  end

  defp evaluate_blackboard_update(pid, sid, hist, mo) do
    # Simula avaliação se o usuário deve ser interrompido
    case Client.chat_completion(hist, if(mo, do: [provider: mo.provider, model: mo.model], else: [])) do
      {:ok, %{"content" => resp}} ->
        if String.upcase(resp) != "IGNORE" do
          send(pid, {:assistant_reply_finished, resp})
          PubSub.broadcast("session:#{sid}", {:agent_response, resp})
        end
      _ -> :ok
    end
  end

  # --- Boilerplate API ---
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:session_id]))
  defp via_tuple(id), do: {:via, Registry, {Pincer.Session.Registry, id}}
  def process_input(id, input), do: GenServer.call(via_tuple(id), {:process_input, input})
  def get_status(id), do: GenServer.call(via_tuple(id), :get_status)

  @impl true
  def handle_info({:assistant_reply_finished, response}, state) do
    new_history = state.history ++ [%{"role" => "assistant", "content" => response}]
    {:noreply, %{state | history: new_history}}
  end

  @impl true
  def handle_info({:executor_finished, final_history, response}, state) do
    publish(state.session_id, {:agent_response, response})
    {:noreply, %{state | history: final_history, status: :idle, worker_pid: nil}}
  end
end
