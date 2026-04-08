defmodule Pincer.Channels.Slack.Session do
  @compile {:no_warn_undefined, [
    Pincer.Infra.PubSub
  ]}
  @moduledoc """
  Manages outgoing responses for a specific Slack channel.
  """
  use Pincer.Ports.Channel

  @impl Pincer.Ports.Channel
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
    super(channel_id)
    Pincer.Infra.PubSub.subscribe("session:#{session_id}")
    {:ok, %{channel_id: channel_id, session_id: session_id}}
  end

  @impl Pincer.Ports.Channel
  def handles_session?(id), do: String.starts_with?(id, "slack_")

  @impl Pincer.Ports.Channel
  def resolve_recipient(id) do
    case String.split(id, "_", parts: 2) do
      ["slack", channel_id] -> channel_id
      _ -> id
    end
  end

  @impl Pincer.Ports.Channel
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
