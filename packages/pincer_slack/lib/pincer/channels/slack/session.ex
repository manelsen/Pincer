defmodule Pincer.Channels.Slack.Session do
  @moduledoc """
  Manages outgoing responses for a specific Slack channel.
  """
  use PincerPorts.Channel
  alias Pincer.Channels.Shared.SessionBridge

  @impl PincerPorts.Channel
  def start_link(channel_id) do
    GenServer.start_link(__MODULE__, channel_id, name: via_tuple(channel_id))
  end

  def ensure_started(channel_id) do
    SessionBridge.ensure_started({:slack, channel_id},
      registry: Pincer.Channels.Slack.Registry,
      key: channel_id,
      start_worker: &Pincer.Channels.Slack.SessionSupervisor.start_worker/1,
      rebind: false,
      already_started: :ok_atom
    )
  end

  defp via_tuple(channel_id),
    do:
      SessionBridge.via_tuple(:slack, channel_id,
        registry: Pincer.Channels.Slack.Registry,
        key: channel_id
      )

  @impl true
  def init(channel_id) do
    session_id = SessionBridge.default_session_id(:slack, channel_id)
    super(channel_id)
    SessionBridge.subscribe(session_id)
    {:ok, SessionBridge.initial_state(%{channel_id: channel_id, session_id: session_id})}
  end

  @impl PincerPorts.Channel
  def handles_session?(id), do: SessionBridge.handles_session?(:slack, id)

  @impl PincerPorts.Channel
  def resolve_recipient(id), do: SessionBridge.resolve_recipient(:slack, id)

  @impl PincerPorts.Channel
  def send_message(channel_id, text) do
    Pincer.Channels.Slack.send_message(channel_id, text)
  end

  # --- Session PubSub callbacks ---

  @impl true
  def on_agent_response(text, _usage, state) do
    Logger.info("[SLACK SESSION] Sending response to channel: #{state.channel_id}")
    Pincer.Channels.Slack.send_message(state.channel_id, text)
    state
  end

  # All other events (partial, error, status, thinking, subagent, approval) → macro no-ops
end
