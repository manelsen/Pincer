defmodule Pincer.Session.Server do
  @moduledoc """
  Core da Sessão (Pincer Brain).
  Agnóstico a canais. Apenas recebe input (via call) e emite eventos (via PubSub).
  """
  use GenServer, restart: :transient
  require Logger

  alias Pincer.LLM.Client
  alias Pincer.Storage
  alias Pincer.Core.Executor
  alias Pincer.PubSub

  @identity_file "IDENTITY.md"
  @soul_file "SOUL.md"
  @user_file "USER.md"

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    if File.exists?(@soul_file) do
      persisted = Storage.get_messages(session_id)
      history = if Enum.empty?(persisted), do: [%{"role" => "system", "content" => get_system_prompt()}], else: [%{"role" => "system", "content" => get_system_prompt()} | persisted]
      {:ok, %{mode: :normal, session_id: session_id, history: history, status: :idle, worker_pid: nil}}
    else
      {:ok, %{mode: :bootstrapping, session_id: session_id, current_step: :name, responses: %{}, worker_pid: nil}}
    end
  end

  # --- Entrada (Driving Port) ---

  @impl true
  def handle_call({:process_input, input}, _from, %{mode: :normal} = state) do
    Storage.save_message(state.session_id, "user", input)
    user_msg = %{"role" => "user", "content" => input}
    new_history = state.history ++ [user_msg]

    cond do
      state.status == :working ->
        Task.start(fn -> quick_assistant_reply(self(), state.session_id, new_history, input) end)
        {:reply, {:ok, :butler_notified}, %{state | history: new_history}}

      is_just_chat?(input) ->
        Task.start(fn -> quick_assistant_reply(self(), state.session_id, new_history, input) end)
        {:reply, {:ok, :butler_notified}, %{state | history: new_history}}

      true ->
        # Simplificação: Chama o Executor direto (Agente Polímata)
        {:ok, pid} = Executor.start(self(), state.session_id, new_history)
        {:reply, {:ok, :started}, %{state | history: new_history, worker_pid: pid, status: :working}}
    end
  end

  # --- Saída (Driven Port via Event Bus) ---

  defp publish(session_id, event) do
    PubSub.broadcast("session:#{session_id}", event)
  end

  @impl true
  def handle_info({:assistant_reply_finished, response}, state) do
    new_history = state.history ++ [%{"role" => "assistant", "content" => response}]
    {:noreply, %{state | history: new_history}}
  end

  @impl true
  def handle_info({:sme_status, role, status}, state) do
    msg = "📐 **#{String.capitalize(to_string(role))}**: #{status}"
    publish(state.session_id, {:agent_status, msg})
    {:noreply, %{state | history: state.history ++ [%{"role" => "system", "content" => "[SME STATUS]: #{msg}"}]}}
  end

  @impl true
  def handle_info({:sme_tool_use, tools}, state) do
    publish(state.session_id, {:agent_thinking, "Executando: #{tools}..."})
    {:noreply, state}
  end

  @impl true
  def handle_info({:sme_update, role, content}, state) do
    update_msg = %{"role" => "system", "content" => "[ATUALIZAÇÃO DO #{role}]: #{content}"}
    {:noreply, %{state | history: state.history ++ [update_msg]}}
  end

  @impl true
  def handle_info({:executor_finished, final_history, response}, state) do
    Storage.save_message(state.session_id, "assistant", response)
    publish(state.session_id, {:agent_response, response})
    {:noreply, %{state | history: final_history, status: :idle}}
  end

  @impl true
  def handle_info({:executor_failed, reason}, state) do
    publish(state.session_id, {:agent_error, "Problema técnico: #{inspect(reason)}"})
    {:noreply, %{state | status: :idle}}
  end

  # --- Lógica Interna ---

  defp is_just_chat?(input) do
    input = String.downcase(input)
    String.length(input) < 20 or 
    String.contains?(input, ["oi", "olá", "bom dia", "boa noite", "tudo bem", "quem é você", "ping"])
  end

  defp quick_assistant_reply(session_pid, session_id, history, current_input) do
    semantic_context = Storage.search_similar_messages(current_input, 3)
    long_term_memory = if File.exists?("MEMORIA.md"), do: File.read!("MEMORIA.md"), else: ""

    assistant_prompt = """
    Você é o ASSISTENTE do Pincer.
    ## MEMÓRIA DE LONGO PRAZO:
    #{long_term_memory}
    ## CONTEXTO SEMÂNTICO:
    #{Enum.map(semantic_context, fn m -> "#{m.role}: #{m.content}" end) |> Enum.join("\n")}
    """
    
    assistant_history = [%{"role" => "system", "content" => assistant_prompt}] ++ Enum.take(history, -20)

    case Client.chat_completion(assistant_history) do
      {:ok, %{"content" => response}} ->
        Storage.save_message(session_id, "assistant", response)
        send(session_pid, {:assistant_reply_finished, response})
        # Publica evento diretamente no Bus
        Pincer.PubSub.broadcast("session:#{session_id}", {:agent_response, response})
      _ -> :ok
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:session_id]))
  defp via_tuple(id), do: {:via, Registry, {Pincer.Session.Registry, id}}
  def process_input(id, input), do: GenServer.call(via_tuple(id), {:process_input, input})

  defp get_system_prompt do
    identity = if File.exists?(@identity_file), do: File.read!(@identity_file), else: ""
    soul = if File.exists?(@soul_file), do: File.read!(@soul_file), else: ""
    user = if File.exists?(@user_file), do: File.read!(@user_file), else: ""
    "#{identity}\n\n## SOUL:\n#{soul}\n\n## USUÁRIO:\n#{user}"
  end
end
