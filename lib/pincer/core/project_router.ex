defmodule Pincer.Core.ProjectRouter do
  @moduledoc """
  Command routing and parsing for project-related messages.
  Maintains compatibility with legacy channel calls while supporting the new OTP-native flow.
  """
  require Logger
  alias Pincer.Core.Project.Server, as: ProjectServer
  alias Pincer.Core.ProjectOrchestrator

  @doc """
  Parses a textual command into a structured `{:ok, command, args}` tuple.

  Supports `/status`, `/new`, `/reset`, `/learn`, and `/project` subcommands.
  Returns `:error` for unrecognized input.
  """
  def parse(text) when is_binary(text) do
    case String.split(text, " ", parts: 3) do
      ["/status"] ->
        {:ok, :status, nil}

      ["/new" | rest] ->
        {:ok, :reset, Enum.join(rest, " ")}

      ["/learn" | rest] ->
        {:ok, :learn, Enum.join(rest, " ")}

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

  @doc """
  Dispatches a parsed command to the appropriate handler.

  ## Parameters
    - `cmd` — atom returned by `parse/1` (e.g. `:status`, `:reset`, `:start`)
    - `args` — command arguments (string or tuple)
    - `session_id` — the active session ID
  """
  def handle_command(cmd, args, session_id) do
    case cmd do
      :status ->
        format_status(session_id)

      :reset ->
        handle_reset(session_id, args)

      :learn ->
        handle_learn(session_id, args)

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

  @doc """
  Returns the project kanban board for a session, or a hint if unavailable.
  """
  def kanban(session_id) do
    case ProjectOrchestrator.board(session_id) do
      {:ok, board} ->
        board

      :not_found ->
        "Kanban unavailable for this session. Use /project to start the wizard."
    end
  end

  @doc """
  Starts or resumes the project orchestrator wizard.
  """
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
    # 1. If a model argument is present, attempt to switch model first
    if model_args != "" do
      # Assumes format "provider:model" or just "model".
      # For now, just log and reset.
      # Future: parse model_args into actual provider/model switch.
      Logger.info("[ROUTER] Resetting with model preference: #{model_args}")
    end

    # 2. Reset the session
    Pincer.Core.Session.Server.reset(session_id)
    {:ok, "🧹 Session reset. Loading identity..."}
  end

  defp format_status(session_id) do
    case Pincer.Core.Session.Server.get_status(session_id) do
      {:ok, state} ->
        provider = if state.model_override, do: state.model_override.provider, else: "Default"
        model = if state.model_override, do: state.model_override.model, else: "Default"
        status = if state.status == :working, do: "working", else: "idle"

        in_t = Map.get(state.token_usage_total || %{}, "prompt_tokens", 0)
        out_t = Map.get(state.token_usage_total || %{}, "completion_tokens", 0)

        thinking = state.thinking_level || "off"
        reasoning = if state.reasoning_visible, do: "visible", else: "hidden"

        {:ok,
         """
         Session: #{session_id}
         Model: #{provider}/#{model}
         Tokens this session: #{in_t} in · #{out_t} out
         Thinking: #{thinking} | Reasoning: #{reasoning}
         Status: #{status}
         """}

      _ ->
        {:error, "Could not retrieve session status."}
    end
  end

  defp handle_learn(_session_id, summary) do
    if String.trim(summary) == "" do
      {:handled, "Usage: /learn <lesson or rule the agent should memorize>"}
    else
      case Pincer.Ports.Storage.save_learning("correction", summary) do
        {:ok, _} -> {:handled, "✅ Lesson memorized successfully in the Knowledge Graph."}
        {:error, e} -> {:handled, "❌ Failed to memorize lesson: #{inspect(e)}"}
      end
    end
  end
end
