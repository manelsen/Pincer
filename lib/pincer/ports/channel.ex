defmodule Pincer.Ports.Channel do
  @moduledoc """
  Behaviour defining the contract for communication channels in Pincer.

  A Channel represents a bidirectional communication interface between Pincer
  and external systems (Telegram, CLI, Discord, Slack, etc.). Each channel is
  responsible for:

  1. **Receiving messages** from the external system and routing them to sessions
  2. **Sending messages** back to users in the external system

  ## Architecture

  Channels are started by `Pincer.Channels.Supervisor` and managed through
  `Pincer.Channels.Factory`. The factory reads channel configurations from
  `config.yaml` and instantiates only enabled channels.

  ## Implementing a New Channel

  To implement a new channel, use the `__using__` macro which provides default
  GenServer scaffolding:

      defmodule Pincer.Channels.MyChannel do
        use Pincer.Ports.Channel

        @impl true
        def init(config) do
          # Initialize your channel with config from config.yaml
          {:ok, %{config: config}}
        end

        @impl Pincer.Ports.Channel
        def send_message(recipient_id, content) do
          # Send message to the external system
          :ok
        end
      end

  Then register it in `config.yaml`:

      channels:
        my_channel:
          enabled: true
          adapter: "Pincer.Channels.MyChannel"
          # ... channel-specific config

  ## Callbacks

  - `start_link/1` - Starts the channel process (required)
  - `send_message/2` - Sends a message to a recipient (optional)

  The `send_message/2` callback is optional because some channels may be
  receive-only (webhooks without outbound capability).

  ## Session Integration

  Channels should route incoming messages to `Pincer.Core.Session.Server.process_input/2`:

      session_id = "telegram_\#{chat_id}"
      Server.process_input(session_id, text)

  The session ID format is typically `"\#{channel_name}_\#{external_user_id}"`.

  ## See Also

  - `Pincer.Channels.Telegram` - Telegram bot implementation
  - `Pincer.Channels.CLI` - Terminal-based channel
  - `Pincer.Channels.Factory` - Channel instantiation logic
  - `Pincer.Channels.Supervisor` - Channel lifecycle management
  """

  @doc """
  Starts the channel process with the given configuration.

  The configuration is a map read from `config.yaml` under the channel's section.
  Channels should extract their settings (tokens, API keys, etc.) from this map.

  ## Parameters

    - `config` - Map containing channel-specific configuration from config.yaml

  ## Returns

    - `{:ok, pid}` - Channel started successfully
    - `{:ignore}` - Channel should not be started (e.g., missing credentials)
    - `{:error, reason}` - Channel failed to start

  ## Examples

      # In config.yaml:
      # channels:
      #   telegram:
      #     enabled: true
      #     token_env: "TELEGRAM_BOT_TOKEN"

      def start_link(config) do
        token = System.get_env(config["token_env"])
        if token, do: GenServer.start_link(__MODULE__, config), else: :ignore
      end
  """
  @callback start_link(config :: map()) :: GenServer.on_start()

  @doc """
  Sends a message to a recipient through this channel.

  ## Parameters

    - `recipient_id` - Unique identifier for the recipient in this channel
                      (e.g., Telegram chat_id, Discord channel_id)
    - `content` - Text content to send

  ## Returns

    - `{:ok, message_id}` - Message sent successfully, with an internal ID for updates
    - `:ok` - Message sent successfully (no ID returned)
    - `{:error, reason}` - Failed to send message
  """
  @callback send_message(recipient_id :: String.t(), content :: String.t()) ::
              :ok | {:ok, any()} | {:error, any()}

  @doc """
  Updates an existing message sent via this channel. Useful for streaming.

  ## Parameters

    - `recipient_id` - Unique identifier for the recipient
    - `message_id` - The ID returned by a previous `send_message` call
    - `content` - The new content for the message

  ## Returns

    - `:ok` - Message updated successfully
    - `{:error, reason}` - Failed to update message
  """
  @callback update_message(recipient_id :: String.t(), message_id :: any(), content :: String.t()) ::
              :ok | {:error, any()}

  @optional_callbacks send_message: 2, update_message: 3

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Pincer.Ports.Channel
      use GenServer
      require Logger

      @doc """
      Default implementation that starts the GenServer with the module name.
      """
      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @doc """
      Default implementation that accepts initial state.
      """
      def init(state), do: {:ok, state}

      defoverridable start_link: 1, init: 1
    end
  end
end
