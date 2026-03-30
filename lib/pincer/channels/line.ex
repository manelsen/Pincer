defmodule Pincer.Channels.Line do
  @moduledoc """
  LINE Messaging API channel adapter.

  A Supervisor that starts the LINE channel process tree. Implements the
  `Pincer.Ports.Channel` behaviour for integration with Pincer's channel
  infrastructure.

  ## Architecture

  ```
  Pincer.Channels.Line (Supervisor)
  └── (children added as needed for webhook handling)
  ```

  ## Configuration

  In `config.yaml`:

      channels:
        line:
          enabled: true
          adapter: "Pincer.Channels.Line"

  Set the environment variable:

      export LINE_CHANNEL_ACCESS_TOKEN="your-channel-access-token"

  If the token is missing, the channel gracefully ignores itself (`:ignore`).

  ## Session Mapping

  Session IDs are formatted as `"line_\#{userId}"`, where `userId` is the LINE
  user identifier from webhook events.

  ## Webhook Handling

  Incoming webhook events are parsed by `parse_webhook_events/1`, which
  extracts text messages and maps them to structured event tuples. The
  `handle_webhook/2` function validates the request signature and routes
  text messages to the appropriate session.

  ## See Also

  - `Pincer.Channels.Line.Session` - Per-user session GenServer
  - `Pincer.Channels.Line.API` - LINE Messaging API client
  - `Pincer.Channels.Shared.WebhookVerifier` - Signature validation
  """

  use Supervisor
  @behaviour Pincer.Ports.Channel
  require Logger

  @doc """
  Starts the LINE channel supervisor.

  If `LINE_CHANNEL_ACCESS_TOKEN` is not set, returns `:ignore` to skip
  this channel.
  """
  @spec start_link(config :: map()) :: Supervisor.on_start()
  @impl Pincer.Ports.Channel
  def start_link(config) do
    token = System.get_env("LINE_CHANNEL_ACCESS_TOKEN")

    if is_nil(token) or token == "" do
      Logger.warning("LINE_CHANNEL_ACCESS_TOKEN not set. Channel ignored.")
      :ignore
    else
      Supervisor.start_link(__MODULE__, config, name: __MODULE__)
    end
  end

  @impl Supervisor
  def init(_config) do
    Logger.info("Starting LINE Channel...")
    children = []
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Sends a text message to a LINE user via push_message.

  Delegates to `Pincer.Channels.Line.API.push_message/2` with a text
  message object.
  """
  @spec send_message(chat_id :: String.t(), text :: String.t()) ::
          {:ok, map()} | {:error, term()}
  @impl Pincer.Ports.Channel
  def send_message(chat_id, text) do
    Pincer.Channels.Line.API.push_message(chat_id, [
      %{"type" => "text", "text" => text}
    ])
  end

  @doc """
  Updates a message by sending a follow-up push message.

  LINE has no edit API, so updates are implemented as new messages.
  """
  @spec update_message(chat_id :: String.t(), message_id :: any(), text :: String.t()) ::
          {:ok, map()} | {:error, term()}
  @impl Pincer.Ports.Channel
  def update_message(chat_id, _message_id, text) do
    send_message(chat_id, text)
  end

  @doc """
  Checks if a session ID belongs to the LINE channel.
  """
  @spec handles_session?(session_id :: String.t()) :: boolean()
  @impl Pincer.Ports.Channel
  def handles_session?(session_id) do
    String.starts_with?(session_id, "line_")
  end

  @doc """
  Resolves the external LINE user ID from a session ID.

  Strips the `"line_"` prefix to obtain the raw userId.
  """
  @spec resolve_recipient(session_id :: String.t()) :: String.t()
  @impl Pincer.Ports.Channel
  def resolve_recipient(session_id) do
    case String.split(session_id, "_", parts: 2) do
      ["line", user_id] -> user_id
      _ -> session_id
    end
  end

  @doc """
  Validates the webhook signature and routes text messages to sessions.

  Returns `{:ok, events}` on success, `{:error, :invalid_signature}` if
  signature verification fails.
  """
  @spec handle_webhook(body :: String.t(), signature :: String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def handle_webhook(body, signature) do
    secret = System.get_env("LINE_CHANNEL_SECRET") || ""

    case Pincer.Channels.Shared.WebhookVerifier.verify_line(body, secret, signature) do
      :ok ->
        payload = Jason.decode!(body)
        events = parse_webhook_events(payload)
        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses a LINE webhook payload into a list of structured event maps.

  Filters to text message events only, extracting `userId`, `text`, and
  `replyToken` from each event.
  """
  @spec parse_webhook_events(payload :: map()) :: [
          %{user_id: String.t(), text: String.t(), reply_token: String.t()}
        ]
  def parse_webhook_events(%{"events" => events}) when is_list(events) do
    events
    |> Enum.filter(&text_message_event?/1)
    |> Enum.map(&extract_event/1)
  end

  def parse_webhook_events(_), do: []

  @doc """
  Builds a session ID from a LINE user ID.
  """
  @spec session_id(user_id :: String.t()) :: String.t()
  def session_id(user_id) do
    "line_#{user_id}"
  end

  defp text_message_event?(%{
         "type" => "message",
         "message" => %{"type" => "text"}
       }),
       do: true

  defp text_message_event?(_), do: false

  defp extract_event(%{
         "source" => %{"userId" => user_id},
         "message" => %{"text" => text},
         "replyToken" => reply_token
       }) do
    %{user_id: user_id, text: text, reply_token: reply_token}
  end
end
