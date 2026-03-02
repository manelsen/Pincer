defmodule Pincer.Channels.Supervisor do
  @moduledoc """
  Supervisor that manages all communication channel processes.

  This supervisor is responsible for starting and monitoring all enabled
  channels (Telegram, CLI, Discord, etc.) defined in `config.yaml`. It uses
  `Pincer.Channels.Factory` to determine which channels to start.

  ## Supervision Tree Position

  The Channels Supervisor sits under the main application supervisor:

  ```
  Pincer.Application
  └── Pincer.Channels.Supervisor
      ├── Pincer.Channels.Telegram (Supervisor)
      │   └── Pincer.Channels.Telegram.UpdatesProvider
      └── Pincer.Channels.CLI (GenServer)
  ```

  ## Strategy

  Uses `:one_for_one` strategy, meaning if a channel crashes, only that
  channel is restarted. Other channels continue operating unaffected.

  ## Startup Process

  1. `start_link/1` is called by the application supervisor
  2. `init/1` calls `Factory.create_channel_specs/0` to get enabled channels
  3. Each channel's `start_link/1` is called with its configuration
  4. Channels that return `:ignore` (e.g., missing credentials) are skipped

  ## Configuration

  Channels are configured in `config.yaml`:

      channels:
        telegram:
          enabled: true
          adapter: "Pincer.Channels.Telegram"
          token_env: "TELEGRAM_BOT_TOKEN"
        cli:
          enabled: true
          adapter: "Pincer.Channels.CLI"

  ## Examples

      # The supervisor is typically started by the application
      # but can be started manually for testing:
      Pincer.Channels.Supervisor.start_link([])

      # Check running channels
      Supervisor.which_children(Pincer.Channels.Supervisor)
      # => [{Pincer.Channels.CLI, #PID<0.123.0>, :worker, [Pincer.Channels.CLI]},
      #     {Pincer.Channels.Telegram, #PID<0.124.0>, :supervisor, [...]}]

  ## Adding a New Channel

  1. Implement `Pincer.Channel` behaviour in your module
  2. Add configuration to `config.yaml`:

         channels:
           my_channel:
             enabled: true
             adapter: "Pincer.Channels.MyChannel"
             # ... channel-specific config

  3. The channel will be automatically started on application boot

  ## See Also

  - `Pincer.Channels.Factory` - Creates channel specs from config
  - `Pincer.Channel` - Behaviour for channel implementations
  - `Pincer.Channels.Telegram` - Example channel implementation
  """

  use Supervisor
  require Logger
  alias Pincer.Channels.Factory

  @doc """
  Starts the Channels Supervisor.

  This function is called by the main application supervisor during startup.
  It initializes the supervisor which then starts all enabled channels.

  ## Parameters

    - `init_arg` - Initialization argument (typically empty list or keyword list)

  ## Returns

    - `{:ok, pid}` - Supervisor started successfully
    - `{:ignore}` - Supervisor should not be started
    - `{:error, reason}` - Failed to start

  ## Examples

      {:ok, pid} = Pincer.Channels.Supervisor.start_link([])
  """
  @spec start_link(init_arg :: term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    Logger.info("Channels Supervisor starting...")

    children = Factory.create_channel_specs()

    Supervisor.init(children, strategy: :one_for_one)
  end
end
