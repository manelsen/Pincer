defmodule Pincer.Channels.Feishu do
  @compile {:no_warn_undefined, [
    Pincer.Channels.Shared.WebhookVerifier
  ]}
  @moduledoc """
  Feishu (Lark) channel adapter.

  A Supervisor that starts the Feishu channel process tree. Implements the
  `Pincer.Ports.Channel` behaviour for integration with Pincer's channel
  infrastructure.

  ## Architecture

  ```
  Pincer.Channels.Feishu (Supervisor)
  └── Pincer.Channels.Feishu.API (TokenCache GenServer)
  ```

  ## Configuration

  Requires the environment variables:

      export FEISHU_APP_ID="your-app-id"
      export FEISHU_APP_SECRET="your-app-secret"

  If either is missing, the channel returns `:ignore` during startup.

  ## Session Mapping

  Session IDs are formatted as `"feishu_\#{open_id}"`, where `open_id` is
  the Feishu user identifier from webhook events.

  ## Webhook Handling

  Incoming `im.message.receive_v1` events are parsed by `parse_webhook_event/1`,
  which extracts sender, chat, message metadata, and text content into a
  structured map.

  ## See Also

  - `Pincer.Channels.Feishu.API` - Feishu HTTP API client
  - `Pincer.Channels.Feishu.Cards` - Card payload construction
  - `Pincer.Channels.Shared.WebhookVerifier` - Signature validation
  """

  use Supervisor
  @behaviour Pincer.Ports.Channel
  require Logger

  alias Pincer.Channels.Feishu.{API, Cards}
  alias Pincer.Channels.Shared.WebhookVerifier

  @doc """
  Starts the Feishu channel supervisor.

  If `FEISHU_APP_ID` or `FEISHU_APP_SECRET` is not set, returns `:ignore`
  to skip this channel.
  """
  @spec start_link(config :: map()) :: Supervisor.on_start()
  @impl Pincer.Ports.Channel
  def start_link(config) do
    app_id = System.get_env("FEISHU_APP_ID")
    app_secret = System.get_env("FEISHU_APP_SECRET")

    if is_nil(app_id) or is_nil(app_secret) do
      Logger.warning("FEISHU_APP_ID or FEISHU_APP_SECRET not set. Channel ignored.")
      :ignore
    else
      Supervisor.start_link(__MODULE__, config, name: __MODULE__)
    end
  end

  @impl Supervisor
  def init(_config) do
    Logger.info("Starting Feishu Channel...")
    children = [{API, []}]
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Sends a text message to a Feishu chat.

  Delegates to `Pincer.Channels.Feishu.API.send_message/3` with a text
  content payload.
  """
  @spec send_message(chat_id :: String.t(), text :: String.t()) ::
          {:ok, map()} | {:error, term()}
  @impl Pincer.Ports.Channel
  def send_message(chat_id, text) do
    API.send_message(chat_id, Jason.encode!(%{"text" => text}), "text")
  end

  @doc """
  Updates a streaming card with new text content.

  Builds a card payload from the text and delegates to
  `Pincer.Channels.Feishu.API.update_card/2`.
  """
  @spec update_message(recipient_id :: String.t(), message_id :: any(), text :: String.t()) ::
          {:ok, map()} | {:error, term()}
  @impl Pincer.Ports.Channel
  def update_message(_recipient_id, message_id, text) do
    API.update_card(message_id, Cards.create_card(text))
  end

  @doc """
  Parses a decoded `im.message.receive_v1` webhook payload into a structured map.

  Extracts `open_id`, `chat_id`, `message_id`, `msg_type`, and parsed `content`.

  Returns `:error` for malformed payloads.
  """
  @spec parse_webhook_event(payload :: map()) ::
          %{
            open_id: String.t(),
            chat_id: String.t(),
            message_id: String.t(),
            content: String.t(),
            msg_type: String.t()
          }
          | :error
  def parse_webhook_event(%{
        "event" => %{
          "sender" => %{"sender_id" => %{"open_id" => open_id}},
          "message" => %{
            "chat_id" => chat_id,
            "message_id" => message_id,
            "message_type" => msg_type,
            "content" => content_json
          }
        }
      }) do
    content =
      case Jason.decode(content_json) do
        {:ok, %{"text" => text}} -> text
        _ -> content_json
      end

    %{
      open_id: open_id,
      chat_id: chat_id,
      message_id: message_id,
      content: content,
      msg_type: msg_type
    }
  rescue
    _ -> :error
  end

  def parse_webhook_event(_), do: :error

  @doc """
  Validates a Feishu webhook signature.

  Delegates to `Pincer.Channels.Shared.WebhookVerifier.verify_feishu/4`.
  """
  @spec validate_webhook(
          timestamp :: String.t(),
          nonce :: String.t(),
          body :: String.t(),
          signature :: String.t()
        ) ::
          :ok | {:error, term()}
  def validate_webhook(timestamp, nonce, body, signature) do
    WebhookVerifier.verify_feishu(timestamp, nonce, body, signature)
  end

  @doc """
  Builds a session ID from a Feishu `open_id`.
  """
  @spec format_session_id(open_id :: String.t()) :: String.t()
  def format_session_id(open_id) do
    "feishu_#{open_id}"
  end
end
