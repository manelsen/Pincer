defmodule Pincer.Core.Project.Adapter do
  @moduledoc """
  Implements `PincerPorts.Project` on top of the Core project modules.

  Channel adapters ask the port for wizard routing, prompts and delivery so
  they never import `Pincer.Core.Project*` themselves.
  """

  @behaviour PincerPorts.Project

  alias Pincer.Core.{ProjectFlowDelivery, ProjectOrchestrator, ProjectRouter}

  @impl true
  def handle_command(command, args, session_id),
    do: ProjectRouter.handle_command(command, args, session_id)

  @impl true
  def continue_if_collecting(session_id, text, opts),
    do: ProjectRouter.continue_if_collecting(session_id, text, opts)

  @impl true
  def kickoff(session_id), do: ProjectRouter.kickoff(session_id)

  @impl true
  def kanban(session_id), do: ProjectRouter.kanban(session_id)

  @impl true
  def project(session_id, seed), do: ProjectRouter.project(session_id, seed)

  @impl true
  def phase(session_id), do: ProjectOrchestrator.phase(session_id)

  @impl true
  def on_agent_response(session_id, opts), do: ProjectFlowDelivery.on_response(session_id, opts)

  @impl true
  def on_agent_error(session_id, opts), do: ProjectFlowDelivery.on_error(session_id, opts)
end
