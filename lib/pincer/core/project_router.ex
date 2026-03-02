defmodule Pincer.Core.ProjectRouter do
  @moduledoc """
  Command routing and parsing for project-related messages.
  Maintains compatibility with legacy channel calls while supporting the new OTP-native flow.
  """
  require Logger
  alias Pincer.Core.Project.Server, as: ProjectServer
  alias Pincer.Core.ProjectOrchestrator

  def parse(text) when is_binary(text) do
    case String.split(text, " ", parts: 3) do
      ["/status"] ->
        {:ok, :status, nil}

      ["/new" | rest] ->
        {:ok, :reset, Enum.join(rest, " ")}

      ["/reset" | rest] ->
        {:ok, :reset, Enum.join(rest, " ")}

      ["/project", "start" | rest] ->
        {:ok, :start, Enum.join(rest, " ")}

      ["/project", "approve", id] ->
        {:ok, :approve, id}

      ["/project", "pause", id] ->
        {:ok, :pause, id}

      ["/project", "resume", id] ->
        {:ok, :resume, id}

      ["/project", "stop", id] ->
        {:ok, :stop, id}

      ["/project", "modify", id_and_tasks] ->
        case String.split(id_and_tasks, " ", parts: 2) do
          [id, tasks] -> {:ok, :modify, {id, tasks}}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse(_), do: :error

  def handle_command(cmd, args, session_id) do
    case cmd do
      :status ->
        format_status(session_id)

      :reset ->
        handle_reset(session_id, args)

      :start ->
        ProjectOrchestrator.start(session_id, args)

      :approve ->
        ProjectServer.approve(args)

      :pause ->
        ProjectServer.pause(args)

      :resume ->
        ProjectServer.resume(args)

      :stop ->
        ProjectServer.stop(args)

      :modify ->
        {id, tasks} = args
        ProjectServer.update_plan(id, tasks)
    end
  end

  # --- Legacy Compatibility & Real Logic ---

  def kanban(session_id) do
    case ProjectOrchestrator.board(session_id) do
      {:ok, board} ->
        board

      :not_found ->
        "Kanban indisponivel para esta sessao. Use /project para iniciar o wizard."
    end
  end

  def project(session_id, seed \\ nil), do: ProjectOrchestrator.start(session_id, seed)

  @spec continue_if_collecting(String.t(), String.t(), keyword()) ::
          :not_handled | {:handled, String.t()}
  def continue_if_collecting(session_id, text, opts \\ []) do
    has_attachments = Keyword.get(opts, :has_attachments, false)

    cond do
      has_attachments ->
        :not_handled

      String.trim(text) == "" ->
        :not_handled

      true ->
        case ProjectOrchestrator.continue(session_id, text) do
          {:handled, response} -> {:handled, response}
          :not_active -> :not_handled
        end
    end
  end

  @spec on_agent_response(String.t()) :: :noop | {:next, any()} | {:completed, any()}
  def on_agent_response(session_id) do
    ProjectOrchestrator.on_agent_response(session_id)
  end

  @spec on_agent_error(String.t()) :: :noop | {:retry, any()} | {:paused, any()}
  def on_agent_error(session_id) do
    ProjectOrchestrator.on_agent_error(session_id)
  end

  @spec kickoff(String.t()) :: :not_ready | {:ok, any()} | :already_started | :completed
  def kickoff(session_id) do
    ProjectOrchestrator.kickoff(session_id)
  end

  defp handle_reset(session_id, model_args) do
    # 1. Se houver argumento, tenta trocar o modelo primeiro
    if model_args != "" do
      # Aqui assumimos formato "provider:model" ou apenas "model"
      # Para simplificar agora, vamos apenas logar e resetar. 
      # Futuramente podemos dar parse real no model_args.
      Logger.info("[ROUTER] Resetting with model preference: #{model_args}")
    end

    # 2. Reseta a sessão
    Pincer.Core.Session.Server.reset(session_id)
    {:ok, "🧹 Sessão resetada. Carregando identidade..."}
  end

  defp format_status(session_id) do
    case Pincer.Core.Session.Server.get_status(session_id) do
      {:ok, state} ->
        provider = if state.model_override, do: state.model_override.provider, else: "Default"
        model = if state.model_override, do: state.model_override.model, else: "Default"
        status = if state.status == :working, do: "🏗️ Busy", else: "😴 Idle"

        {:ok,
         """
         📊 *Session Status*
         ━━━━━━━━━━━━━━━
         🆔 *ID*: `#{session_id}`
         📡 *Status*: #{status}
         🏢 *Provider*: `#{provider}`
         🤖 *Model*: `#{model}`
         📜 *History*: #{length(state.history)} messages
         """}

      _ ->
        {:error, "Não foi possível obter o status da sessão."}
    end
  end
end
