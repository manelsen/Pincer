defmodule Pincer.Channels.Slack do
  @moduledoc """
  Slack channel implementation using Slack (Socket Mode).
  """
  use Supervisor
  @behaviour PincerPorts.Channel
  require Logger
  alias Pincer.Channels.Shared.Formatting

  @impl PincerPorts.Channel
  def start_link(config) do
    if is_map(config) do
      Application.put_env(:pincer, :slack_channel_config, config)
    end

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
        {Slack.Supervisor,
         [
           app_token: app_token,
           bot_token: bot_token,
           bot: Pincer.Channels.Slack.Handler
         ]},
        {Pincer.Channels.Slack.SessionSupervisor, []}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    else
      Logger.warning(
        "Slack tokens missing (SLACK_APP_TOKEN or SLACK_BOT_TOKEN). Slack channel disabled."
      )

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

    case api_client().post("chat.update", token, %{
           channel: channel_id,
           ts: message_id,
           text: formatted_text
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def api_client do
    Application.get_env(:pincer, :slack_api, Pincer.Channels.Slack.API.Adapter)
  end

  # Basic Markdown to Slack mrkdwn conversion
  def markdown_to_mrkdwn(text) do
    Formatting.markdown_to_mrkdwn(text)
  end
end

defmodule Pincer.Channels.Slack.Handler do
  @moduledoc """
  Handles Slack events using the Slack.Bot behaviour.
  """
  use Slack.Bot
  require Logger
  alias Pincer.Channels.Shared.{Inbound, SessionBridge}

  @impl true
  def handle_event(
        "message",
        %{"text" => text, "user" => user_id, "channel" => channel_id} = _payload,
        _bot
      ) do
    config = Application.get_env(:pincer, :slack_channel_config, %{})
    session_id = "slack_#{channel_id}"
    is_dm = String.starts_with?(to_string(channel_id), "D")
    Logger.info("[SLACK] Message received from #{user_id} in #{channel_id}")

    inbound = %{
      channel: :slack,
      sender_id: user_id,
      is_dm: is_dm,
      config: config,
      text: text,
      has_attachments: false,
      session_id: session_id,
      on_command: fn command ->
        Inbound.handle_standard_command(command, %{
          channel: :slack,
          session_id: session_id,
          sender_id: user_id,
          is_dm: is_dm,
          ensure_session: fn -> ensure_session_started(session_id) end,
          send_reply: fn reply -> Pincer.Channels.Slack.send_message(channel_id, reply) end
        })
      end,
      on_denied: fn message -> Pincer.Channels.Slack.send_message(channel_id, message) end,
      on_project_response: fn response, _sid ->
        Pincer.Channels.Slack.send_message(channel_id, response)
      end,
      on_message: fn content ->
        Inbound.dispatch_session_message(session_id, content,
          ensure_session: fn -> ensure_session_started(session_id) end,
          ensure_worker: fn -> Pincer.Channels.Slack.Session.ensure_started(channel_id) end
        )
      end
    }

    Inbound.route(inbound)
    :ok
  end

  def handle_event(type, payload, _bot) do
    Logger.debug("[SLACK] Received unhandled event type #{type}: #{inspect(payload)}")
    :ok
  end

  defp ensure_session_started(session_id) do
    case SessionBridge.ensure_started(session_id,
           strategy: :ensure_started
         ) do
      {:ok, _pid} ->
        Logger.info("[SLACK] Session ready: #{session_id}")
        :ok

      {:error, reason} ->
        Logger.error("[SLACK] Could not start session #{session_id}: #{inspect(reason)}")
        :ok
    end
  end
end
