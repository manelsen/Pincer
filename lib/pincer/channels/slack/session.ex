defmodule Pincer.Channels.Slack.Session do
  @moduledoc """
  Manages outgoing responses for a specific Slack channel.
  """
  use GenServer
  require Logger

  def start_link(channel_id) do
    GenServer.start_link(__MODULE__, channel_id, name: via_tuple(channel_id))
  end

  def ensure_started(channel_id) do
    case Pincer.Channels.Slack.SessionSupervisor.start_worker(channel_id) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      err -> err
    end
  end

  defp via_tuple(channel_id), do: {:via, Registry, {Pincer.Channels.Slack.Registry, channel_id}}

  @impl true
  def init(channel_id) do
    session_id = "slack_#{channel_id}"
    Pincer.Infra.PubSub.subscribe("session:#{session_id}")
    {:ok, %{channel_id: channel_id, session_id: session_id}}
  end

  @impl true
  def handle_info({:agent_response, response, _usage}, state) do
    Logger.info("[SLACK SESSION] Sending response to channel: #{state.channel_id}")
    Pincer.Channels.Slack.send_message(state.channel_id, response)
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_response, response}, state) do
    handle_info({:agent_response, response, nil}, state)
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
