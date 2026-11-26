defmodule Pincer.Channels.Telegram do
  @moduledoc """
  Telegram bot channel supervisor and `PincerPorts.Channel` entrypoint.

  Coordinates Telegram bot lifecycle and delegates responsibilities to focused
  submodules under `Pincer.Channels.Telegram.*`:

  - `Pincer.Channels.Telegram.UpdatesProvider` - Long-polling GenServer & delivery subscriber
  - `Pincer.Channels.Telegram.Poller` - Offset persistence, polling backoff & delivery routing
  - `Pincer.Channels.Telegram.Update` - Inbound update dispatch & DM policy enforcement
  - `Pincer.Channels.Telegram.Commands` - Slash command handling & bot command registration
  - `Pincer.Channels.Telegram.Menu` - Reply keyboards, inline menus & callback queries
  - `Pincer.Channels.Telegram.Media` - Attachment extraction & Whisper audio transcription
  - `Pincer.Channels.Telegram.Formatter` - Markdown/HTML translation & truncation helpers
  - `Pincer.Channels.Telegram.Transport` - Outbound Bot API sending, editing & chunking
  - `Pincer.Channels.Telegram.Session` - Per-chat streaming session GenServer

  ## Architecture

  ```
  Pincer.Channels.Telegram (Supervisor)
  ├── Pincer.Channels.Telegram.SessionSupervisor (DynamicSupervisor)
  └── Pincer.Channels.Telegram.UpdatesProvider (GenServer - Poller)
  ```

  ## Configuration

  In `config.yaml`:

      channels:
        telegram:
          enabled: true
          adapter: "Pincer.Channels.Telegram"
          token_env: "TELEGRAM_BOT_TOKEN"

  If the token environment variable is missing or empty, `init/1` returns
  `:ignore` so the channel stays disabled cleanly.
  """

  use Supervisor
  @behaviour PincerPorts.Channel
  require Logger

  alias Pincer.Channels.Telegram.{
    Commands,
    Formatter,
    Menu,
    SessionSupervisor,
    Transport,
    UpdatesProvider
  }

  @doc """
  Starts the Telegram channel supervisor.
  """
  @spec start_link(config :: map()) :: Supervisor.on_start()
  @impl PincerPorts.Channel
  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl Supervisor
  def init(config) do
    token_var = Map.get(config, "token_env", "TELEGRAM_BOT_TOKEN")
    token = System.get_env(token_var)

    if token && token != "" do
      Logger.info("Starting Telegram Channel (Token OK)...")
      Application.put_env(:telegex, :token, token)
      Application.put_env(:pincer, :telegram_channel_config, config)

      children =
        if Mix.env() == :test,
          do: [SessionSupervisor],
          else: [SessionSupervisor, UpdatesProvider]

      Supervisor.init(children, strategy: :one_for_one)
    else
      Logger.warning("Telegram token not found. Channel ignored.")
      :ignore
    end
  end

  @doc """
  Sends a text message to a Telegram chat.
  """
  @spec send_message(chat_id :: String.t() | integer(), text :: String.t(), opts :: keyword()) ::
          {:ok, integer() | any()} | {:error, any()}
  @impl PincerPorts.Channel
  defdelegate send_message(chat_id, text, opts \\ []), to: Transport

  @doc """
  Updates an existing Telegram message.
  """
  @spec update_message(
          chat_id :: String.t() | integer(),
          message_id :: integer(),
          text :: String.t(),
          opts :: keyword()
        ) :: :ok | {:error, any()}
  @impl PincerPorts.Channel
  defdelegate update_message(chat_id, message_id, text, opts \\ []), to: Transport

  @doc """
  Sends a local file as a document to a Telegram chat.
  """
  @spec send_document(
          chat_id :: String.t() | integer(),
          file_path :: String.t(),
          opts :: keyword()
        ) :: :ok | {:error, any()}
  defdelegate send_document(chat_id, file_path, opts \\ []), to: Transport

  @doc """
  Converts standard Markdown and/or safe HTML into Telegram-compatible HTML.
  """
  @spec markdown_to_html(String.t() | nil) :: String.t()
  defdelegate markdown_to_html(text), to: Formatter

  @doc false
  @spec register_commands() :: :ok
  defdelegate register_commands(), to: Commands

  @doc """
  Returns Telegram reply markup for menu affordance.
  """
  @spec menu_reply_markup() :: map()
  defdelegate menu_reply_markup(), to: Menu

  @doc """
  Returns the configured Telegram API client module.
  """
  @spec api_client() :: module()
  defdelegate api_client(), to: Transport
end
