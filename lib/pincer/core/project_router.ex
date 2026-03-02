defmodule Pincer.Core.ProjectRouter do
  @moduledoc """
  Core-first routing for project workflow commands.

  Keeps channel adapters slim by centralizing `/project` and `/kanban` behavior.
  """

  alias Pincer.Core.ProjectBoard
  alias Pincer.Core.ProjectOrchestrator

  @doc """
  Handles `/project` command for a session.
  """
  @spec project(String.t(), String.t() | nil) :: String.t()
  def project(session_id, seed_input \\ nil) when is_binary(session_id) do
    ProjectOrchestrator.start(session_id, seed_input)
  end

  @doc """
  Handles `/kanban` command for a session with fallback board.
  """
  @spec kanban(String.t()) :: String.t()
  def kanban(session_id) when is_binary(session_id) do
    case ProjectOrchestrator.board(session_id) do
      {:ok, session_board} -> session_board
      :not_found -> ProjectBoard.render()
    end
  end

  @doc """
  Continues project wizard from free-form text when active.

  Returns `:not_handled` when attachments are present or no active project wizard
  is collecting requirements for the session.
  """
  @spec continue_if_collecting(String.t(), String.t(), keyword()) ::
          {:handled, String.t()} | :not_handled
  def continue_if_collecting(session_id, text, opts \\ [])
      when is_binary(session_id) and is_binary(text) do
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
end
