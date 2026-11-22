defmodule Pincer.Ports.Project do
  @moduledoc """
  Port for the project wizard as seen from a channel adapter.

  Channels route `/project` and `/kanban` commands, deliver wizard prompts and
  ask whether a project is still collecting answers. All of that is agent
  runtime behaviour, so the port keeps the transport packages independent of
  `Pincer.Core.Project*` while `Core` registers the implementation at boot.

  ## Example

      case Pincer.Ports.Project.continue_if_collecting(session_id, text) do
        {:handled, prompt} -> send_prompt(prompt)
        :not_handled -> route_to_agent(text)
      end
  """

  @type session_id :: String.t()
  @type prompt :: String.t()
  @type flow_outcome :: :not_handled | {:handled, prompt()}

  @callback handle_command(atom(), String.t(), session_id()) :: term()
  @callback continue_if_collecting(session_id(), String.t(), keyword()) :: flow_outcome()
  @callback kickoff(session_id()) :: term()
  @callback kanban(session_id()) :: term()
  @callback project(session_id(), term()) :: term()
  @callback phase(session_id()) :: term()
  @callback on_agent_response(session_id(), keyword()) :: term()
  @callback on_agent_error(session_id(), keyword()) :: term()

  @doc false
  def adapter do
    Application.get_env(:pincer, :project_adapter, Pincer.Core.Project.Adapter)
  end

  def handle_command(command, args, session_id),
    do: adapter().handle_command(command, args, session_id)

  def continue_if_collecting(session_id, text, opts \\ []),
    do: adapter().continue_if_collecting(session_id, text, opts)

  def kickoff(session_id), do: adapter().kickoff(session_id)
  def kanban(session_id), do: adapter().kanban(session_id)
  def project(session_id, seed \\ nil), do: adapter().project(session_id, seed)
  def phase(session_id), do: adapter().phase(session_id)
  def on_agent_response(session_id, opts \\ []), do: adapter().on_agent_response(session_id, opts)
  def on_agent_error(session_id, opts \\ []), do: adapter().on_agent_error(session_id, opts)
end
