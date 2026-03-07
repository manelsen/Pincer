defmodule Pincer.Channels.Slack do
  @moduledoc """
  Slack channel implementation using Slack (Socket Mode).
  """
  use Supervisor
  @behaviour Pincer.Ports.Channel
  require Logger

  @impl Pincer.Ports.Channel
  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(_config) do
    app_token = System.get_env("SLACK_APP_TOKEN")
    bot_token = System.get_env("SLACK_BOT_TOKEN")

    if app_token && bot_token do
      Logger.info("Starting Slack Channel (Socket Mode)...")
      
      children = [
        {Registry, [keys: :unique, name: Pincer.Channels.Slack.Registry]},
        {Slack.Supervisor, [
          app_token: app_token,
          bot_token: bot_token,
          bot: Pincer.Channels.Slack.Handler
        ]},
        {Pincer.Channels.Slack.SessionSupervisor, []}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    else
      Logger.warning("Slack tokens missing (SLACK_APP_TOKEN or SLACK_BOT_TOKEN). Slack channel disabled.")
      :ignore
    end
  end

  @impl true
  def send_message(channel_id, text, _opts \\ []) do
    token = System.get_env("SLACK_BOT_TOKEN")
    
    # Slack uses mrkdwn format
    formatted_text = markdown_to_mrkdwn(text)
    
    case api_client().post("chat.postMessage", token, %{channel: channel_id, text: formatted_text}) do
      {:ok, %{ts: mid}} -> {:ok, mid}
      {:ok, %{"ts" => mid}} -> {:ok, mid}
      {:ok, _} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def update_message(channel_id, message_id, text) do
    token = System.get_env("SLACK_BOT_TOKEN")
    formatted_text = markdown_to_mrkdwn(text)
    
    case api_client().post("chat.update", token, %{channel: channel_id, ts: message_id, text: formatted_text}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def api_client do
    Application.get_env(:pincer, :slack_api, Pincer.Channels.Slack.API.Adapter)
  end

  # Basic Markdown to Slack mrkdwn conversion
  def markdown_to_mrkdwn(text) do
    text
    |> String.replace(~r/\*\*(.*?)\*\*/, "*\\1*") # Bold: **text** -> *text*
    |> String.replace(~r/__(.*?)__/, "_\\1_")   # Underline/Italic: __text__ -> _text_
    # Slack links: [label](url) -> <url|label>
    |> String.replace(~r/\[(.*?)\]\((.*?)\)/, "<\\2|\\1>")
  end
end

defmodule Pincer.Channels.Slack.Handler do
  @moduledoc """
  Handles Slack events using the Slack.Bot behaviour.
  """
  use Slack.Bot
  require Logger
  alias Pincer.Core.Session.Server
  alias Pincer.Core.Structs.IncomingMessage

  @impl true
  def handle_event("message", %{"text" => text, "user" => user_id, "channel" => channel_id} = _payload, _bot) do
    # Routing to Pincer session
    session_id = "slack_#{channel_id}"
    Logger.info("[SLACK] Message received from #{user_id} in #{channel_id}")

    ensure_session_started(session_id)
    Pincer.Channels.Slack.Session.ensure_started(channel_id)

    incoming = IncomingMessage.new(session_id, text)
    Server.process_input(session_id, incoming)
    :ok
  end

  def handle_event(type, payload, _bot) do
    Logger.debug("[SLACK] Received unhandled event type #{type}: #{inspect(payload)}")
    :ok
  end

  defp ensure_session_started(session_id) do
    case Registry.lookup(Pincer.Core.Session.Registry, session_id) do
      [] ->
        Logger.info("[SLACK] Creating new session: #{session_id}")
        Pincer.Core.Session.Supervisor.start_session(session_id)
      [_] ->
        :ok
    end
  end
end
