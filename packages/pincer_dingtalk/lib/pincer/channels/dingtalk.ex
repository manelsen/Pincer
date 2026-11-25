defmodule Pincer.Channels.DingTalk do
  @moduledoc """
  DingTalk robot channel adapter.

  A Supervisor that starts the DingTalk channel process tree. Implements the
  `PincerPorts.Channel` behaviour for integration with Pincer's channel
  infrastructure.

  ## Architecture

  ```
  Pincer.Channels.DingTalk (Supervisor)
  └── Pincer.Channels.DingTalk.API (TokenCache GenServer)
  ```

  ## Configuration

  Requires the following environment variables:

      export DINGTALK_CLIENT_ID="your-app-key"
      export DINGTALK_CLIENT_SECRET="your-app-secret"

  If either is missing, the channel gracefully ignores itself (`:ignore`).

  ## Session Mapping

  Session IDs are formatted as `"dingtalk_\#{staffId}"`, where `staffId` is the
  DingTalk user identifier from webhook events.

  ## Message Routing

  - Group conversations have IDs starting with `"cid"` -- routed via `send_group/3`.
  - Direct messages use user IDs -- routed via `send_dm/3`.

  ## See Also

  - `Pincer.Channels.DingTalk.Session` - Per-user session GenServer
  - `Pincer.Channels.DingTalk.API` - DingTalk HTTP API client
  - `Pincer.Channels.Shared.WebhookVerifier` - Signature validation
  """

  use Supervisor
  @behaviour PincerPorts.Channel
  require Logger

  alias Pincer.Channels.Shared.{Inbound, SessionBridge}

  @doc """
  Starts the DingTalk channel supervisor.

  If `DINGTALK_CLIENT_ID` or `DINGTALK_CLIENT_SECRET` is not set, returns
  `:ignore` to skip this channel.
  """
  @spec start_link(config :: map()) :: Supervisor.on_start()
  @impl PincerPorts.Channel
  def start_link(config) do
    Application.put_env(:pincer, :dingtalk_channel_config, config)
    client_id_env = Map.get(config, "client_id_env", "DINGTALK_CLIENT_ID")
    client_secret_env = Map.get(config, "client_secret_env", "DINGTALK_CLIENT_SECRET")
    client_id = System.get_env(client_id_env)
    client_secret = System.get_env(client_secret_env)

    if is_nil(client_id) or is_nil(client_secret) do
      Logger.warning("#{client_id_env} or #{client_secret_env} not set. Channel ignored.")
      :ignore
    else
      Supervisor.start_link(__MODULE__, config, name: __MODULE__)
    end
  end

  @impl Supervisor
  def init(config) do
    Logger.info("Starting DingTalk Channel...")

    children =
      [
        {Pincer.Channels.DingTalk.API, name: Pincer.Channels.DingTalk.API},
        {Pincer.Channels.DingTalk.SessionSupervisor, []}
      ] ++ webhook_children(config)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp webhook_children(config) do
    if get_in(config, ["webhook", "enabled"]) == true do
      [{Pincer.Channels.DingTalk.Listener, config}]
    else
      []
    end
  end

  @doc """
  Sends a text message to a DingTalk user or group.

  Routes to `send_dm/3` for user IDs or `send_group/3` for group conversation
  IDs (prefixed with `"cid"`).
  """
  @spec send_message(chat_id :: String.t(), text :: String.t()) ::
          {:ok, map()} | {:error, term()}
  @impl PincerPorts.Channel
  def send_message(chat_id, text) do
    msg_param = Jason.encode!(%{"content" => text})

    if group_id?(chat_id) do
      dingtalk_api().send_group(chat_id, msg_param, "sampleText")
    else
      dingtalk_api().send_dm([chat_id], msg_param, "sampleText")
    end
  end

  @doc """
  Updates an existing interactive card with new content.

  Used for streaming partial agent responses into a card.
  The `recipient_id` is unused since card updates target the card instance directly.
  """
  @spec update_message(
          recipient_id :: String.t(),
          message_id :: String.t(),
          content :: String.t()
        ) ::
          {:ok, map()} | {:error, term()}
  @impl PincerPorts.Channel
  def update_message(_recipient_id, message_id, content) do
    Pincer.Channels.DingTalk.API.update_card(message_id, content)
  end

  @doc """
  Checks if a session ID belongs to the DingTalk channel.
  """
  @spec handles_session?(session_id :: String.t()) :: boolean()
  @impl PincerPorts.Channel
  def handles_session?(session_id) do
    String.starts_with?(session_id, "dingtalk_")
  end

  @doc """
  Resolves the external DingTalk staff ID from a session ID.

  Strips the `"dingtalk_"` prefix to obtain the raw staffId.
  """
  @spec resolve_recipient(session_id :: String.t()) :: String.t()
  @impl PincerPorts.Channel
  def resolve_recipient(session_id) do
    case String.split(session_id, "_", parts: 2) do
      ["dingtalk", staff_id] -> staff_id
      _ -> session_id
    end
  end

  @doc """
  Parses a DingTalk robot webhook event into a structured map.

  Extracts `staff_id`, `conversation_id`, `text`, and `msg_type` from the
  incoming payload. Returns the map or `:error` if required fields are missing.

  ## Fields extracted

    - `staff_id` -- from `senderStaffId` (preferred) or `senderId`
    - `conversation_id` -- from `conversationId`
    - `text` -- from `text.content` for text messages
    - `msg_type` -- from `msgtype` or `messageType`
  """
  @spec parse_webhook_event(payload :: map()) :: map() | :error
  def parse_webhook_event(%{"conversationId" => conv_id} = payload) do
    staff_id = payload["senderStaffId"] || payload["senderId"]
    msg_type = payload["msgtype"] || payload["messageType"]
    text = get_in(payload, ["text", "content"]) || ""

    if staff_id && conv_id && msg_type do
      %{
        staff_id: staff_id,
        conversation_id: conv_id,
        text: text,
        msg_type: msg_type
      }
    else
      :error
    end
  end

  def parse_webhook_event(_), do: :error

  @doc """
  Validates a DingTalk webhook signature.

  Delegates to `Pincer.Channels.Shared.WebhookVerifier.verify_dingtalk/3`.
  """
  @spec validate_webhook(timestamp :: String.t(), secret :: String.t(), signature :: String.t()) ::
          :ok | {:error, :invalid_signature}
  def validate_webhook(timestamp, secret, signature) do
    Pincer.Channels.Shared.WebhookVerifier.verify_dingtalk(timestamp, secret, signature)
  end

  @doc """
  Builds a session ID from a DingTalk staff ID.
  """
  @spec format_session_id(staff_id :: String.t()) :: String.t()
  def format_session_id(staff_id) do
    "dingtalk_#{staff_id}"
  end

  @doc """
  Routes a parsed DingTalk robot event into a Pincer session.
  """
  @spec handle_event(map()) :: :ok | {:error, term()}
  def handle_event(%{text: text} = event) when is_binary(text) and text != "" do
    config = Application.get_env(:pincer, :dingtalk_channel_config, %{})
    conversation_id = Map.get(event, :conversation_id)
    staff_id = Map.get(event, :staff_id)
    is_dm = not group_id?(conversation_id)

    context =
      PincerPorts.Session.resolve(
        :dingtalk,
        %{
          staff_id: staff_id,
          conversation_id: conversation_id
        },
        config
      )

    chat_id = if is_dm, do: staff_id, else: conversation_id

    inbound = %{
      channel: :dingtalk,
      sender_id: staff_id,
      is_dm: is_dm,
      config: config,
      text: text,
      has_attachments: false,
      session_id: context.session_id,
      on_command: fn command ->
        Inbound.handle_standard_command(command, %{
          channel: :dingtalk,
          session_id: context.session_id,
          sender_id: staff_id,
          is_dm: is_dm,
          ensure_session: fn -> ensure_session_started(context) end,
          send_reply: fn reply -> send_message(chat_id, reply) end
        })
      end,
      on_denied: fn message -> send_message(chat_id, message) end,
      on_project_response: fn response, _sid -> send_message(chat_id, response) end,
      on_message: fn content ->
        Inbound.dispatch_session_message(context.session_id, content,
          ensure_session: fn -> ensure_session_started(context) end,
          ensure_worker: fn ->
            Pincer.Channels.DingTalk.Session.ensure_started(chat_id, context.session_id)
          end
        )
      end
    }

    case Inbound.route(inbound) do
      {:message, {:error, reason}} -> {:error, reason}
      _other -> :ok
    end
  end

  def handle_event(_event), do: :ok

  defp ensure_session_started(context) do
    SessionBridge.ensure_started(context)
  end

  defp dingtalk_api do
    Application.get_env(:pincer, :dingtalk_api_module, Pincer.Channels.DingTalk.API)
  end

  # Group conversation IDs start with "cid" in DingTalk.
  defp group_id?(id), do: String.starts_with?(to_string(id), "cid")
end
