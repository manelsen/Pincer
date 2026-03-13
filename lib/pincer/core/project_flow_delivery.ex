defmodule Pincer.Core.ProjectFlowDelivery do
  @moduledoc """
  Centralizes channel-facing delivery for `ProjectRouter` progress transitions.

  Channels inject their transport callback; routing and replay policy remain in
  core.
  """

  alias Pincer.Core.ProjectRouter
  alias Pincer.Core.Session.Server

  @spec on_response(String.t(), keyword()) :: :ok
  def on_response(session_id, opts) when is_binary(session_id) do
    router = Keyword.get(opts, :router, ProjectRouter)
    session_server = Keyword.get(opts, :session_server, Server)
    send_message = Keyword.fetch!(opts, :send_message)

    case router.on_agent_response(session_id) do
      {:next, progress} ->
        send_message.("Project Runner: #{progress.status_message}")
        _ = session_server.process_input(session_id, progress.prompt)
        :ok

      {:completed, progress} ->
        send_message.("Project Runner: #{progress.status_message}")
        :ok

      :noop ->
        :ok
    end
  end

  @spec on_error(String.t(), keyword()) :: :ok
  def on_error(session_id, opts) when is_binary(session_id) do
    router = Keyword.get(opts, :router, ProjectRouter)
    session_server = Keyword.get(opts, :session_server, Server)
    send_message = Keyword.fetch!(opts, :send_message)

    case router.on_agent_error(session_id) do
      {:retry, progress} ->
        send_message.("Project Runner: #{progress.status_message}")
        _ = session_server.process_input(session_id, progress.prompt)
        :ok

      {:paused, progress} ->
        send_message.("Project Runner: #{progress.status_message}")
        :ok

      :noop ->
        :ok
    end
  end
end
