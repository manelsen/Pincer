defmodule Pincer.Core.ProjectRouter do
  @moduledoc """
  Command routing and parsing for project-related messages.
  Maintains compatibility with legacy channel calls while supporting the new OTP-native flow.
  """
  alias Pincer.Project.Server
  alias Pincer.Core.ProjectOrchestrator

  def parse(text) when is_binary(text) do
    case String.split(text, " ", parts: 3) do
      ["/project", "start" | rest] -> {:ok, :start, Enum.join(rest, " ")}
      ["/project", "approve", id] -> {:ok, :approve, id}
      ["/project", "pause", id] -> {:ok, :pause, id}
      ["/project", "resume", id] -> {:ok, :resume, id}
      ["/project", "stop", id] -> {:ok, :stop, id}
      ["/project", "modify", id_and_tasks] ->
        case String.split(id_and_tasks, " ", parts: 2) do
          [id, tasks] -> {:ok, :modify, {id, tasks}}
          _ -> :error
        end
      _ -> :error
    end
  end
  
  def parse(_), do: :error

  def handle_command(cmd, args, session_id) do
    case cmd do
      :start -> ProjectOrchestrator.start(session_id, args)
      :approve -> Server.approve(args)
      :pause -> Server.pause(args)
      :resume -> Server.resume(args)
      :stop -> Server.stop(args)
      :modify -> 
        {id, tasks} = args
        Server.update_plan(id, tasks)
    end
  end

  # --- Legacy Compatibility Stubs ---
  def kanban(_session_id), do: "Use `/project list` para ver seus projetos ativos."
  def project(_session_id, _seed \\ nil), do: "Para iniciar um novo projeto, use `/project start <objetivo>`"
  def continue_if_collecting(_session_id, _text, _opts \\ []), do: :not_handled
  def on_agent_response(_session_id), do: :noop
  def on_agent_error(_session_id), do: :noop
  def kickoff(_session_id), do: :not_ready
end
