defmodule Pincer.Channels.CLI do
  @moduledoc """
  Command-line interface channel for direct terminal interaction.

  The CLI channel enables Pincer to operate as a local REPL-style application,
  routing input from a frontend process to sessions and delivering responses
  back to the terminal.

  ## Architecture

  The CLI channel operates as a GenServer that:
  1. Accepts user input via `handle_cast({:user_input, text}, state)`
  2. Routes messages to the `"cli_user"` session
  3. Delivers responses to an attached frontend process via Erlang messages

  ## Frontend Attachment

  The CLI channel supports a "detached" mode where messages are logged instead
  of sent to a frontend. Frontends (local terminal, remote connection) attach
  by calling `attach/0`:

      # Frontend process attaches to receive output
      Pincer.Channels.CLI.attach()

      # Then send input
      GenServer.cast(Pincer.Channels.CLI, {:user_input, "Hello!"})

      # Receive output in mailbox
      receive do
        {:cli_output, text} -> IO.puts(text)
      end

  ## PubSub Integration

  The CLI channel subscribes to `"session:cli_user"` to receive agent events:

  | Event               | Description                    |
  |---------------------|--------------------------------|
  | `{:agent_response, text}` | Agent's response          |
  | `{:agent_status, text}`   | Status updates            |
  | `{:agent_thinking, text}` | Thinking/progress updates |
  | `{:agent_error, text}`    | Error messages            |

  ## Configuration

  In `config.yaml`:

      channels:
        cli:
          enabled: true
          adapter: "Pincer.Channels.CLI"

  No additional configuration is required for the CLI channel.

  ## Session ID

  The CLI channel uses a fixed session ID of `"cli_user"`, making it a
  single-user channel suitable for local development and testing.

  ## Examples

      # Attach frontend (typically done by CLI frontend)
      Pincer.Channels.CLI.attach()

      # Send a message (routed to session)
      GenServer.cast(Pincer.Channels.CLI, {:user_input, "What is Elixir?"})

      # Send outbound message (from dispatcher)
      Pincer.Channels.CLI.send_message("cli_user", "Response text")
  """

  use GenServer
  @behaviour Pincer.Channel
  require Logger

  @doc """
  Starts the CLI channel GenServer.

  Initializes with an empty frontend PID, meaning messages will be logged
  until a frontend attaches via `attach/0`.

  ## Parameters

    - `_config` - Configuration map (unused for CLI channel)

  ## Returns

    - `{:ok, pid}` - Channel started successfully

  ## Examples

      Pincer.Channels.CLI.start_link(%{})
  """
  @spec start_link(config :: map()) :: GenServer.on_start()
  @impl Pincer.Channel
  def start_link(_config) do
    GenServer.start_link(__MODULE__, %{frontend_pid: nil}, name: __MODULE__)
  end

  @doc """
  Attaches the calling process as the frontend for CLI output.

  After attachment, all CLI output will be sent to the calling process
  as `{:cli_output, text}` messages. Also ensures the `"cli_user"` session
  exists.

  ## Returns

    - `:ok` - Attachment successful

  ## Examples

      # In a frontend process
      Pincer.Channels.CLI.attach()

      # Later, receive output
      receive do
        {:cli_output, text} -> IO.puts(text)
      end
  """
  @spec attach() :: :ok
  def attach do
    GenServer.call(__MODULE__, :attach)
  end

  @impl GenServer
  def init(state) do
    Logger.info("CLI Channel Enabled.")
    Pincer.PubSub.subscribe("session:cli_user")
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:attach, {from_pid, _tag}, state) do
    case Registry.lookup(Pincer.Session.Registry, "cli_user") do
      [{_, _}] -> :ok
      [] -> Pincer.Session.Server.start_link(session_id: "cli_user")
    end

    {:reply, :ok, %{state | frontend_pid: from_pid}}
  end

  @doc """
  Sends a message to the CLI frontend.

  This implements the `Pincer.Channel.send_message/2` callback. The message
  is dispatched to the attached frontend via `:dispatch` cast.

  ## Parameters

    - `_chat_id` - Recipient ID (unused, CLI has single user)
    - `text` - Content to send

  ## Returns

    - `:ok` - Always returns success

  ## Examples

      Pincer.Channels.CLI.send_message("cli_user", "Hello from the agent!")
  """
  @spec send_message(chat_id :: String.t(), text :: String.t()) :: :ok
  @impl Pincer.Channel
  def send_message(_chat_id, text) do
    GenServer.cast(__MODULE__, {:dispatch, text})
    :ok
  end

  @doc false
  @impl true
  def handle_cast({:user_input, text}, state) do
    Pincer.Session.Server.process_input("cli_user", text)
    {:noreply, state}
  end

  def handle_cast({:dispatch, text}, state) do
    send_to_frontend(state, text)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:agent_response, text}, state) do
    send_to_frontend(state, text)
    {:noreply, state}
  end

  def handle_info({:agent_status, text}, state) do
    send_to_frontend(state, text)
    {:noreply, state}
  end

  def handle_info({:agent_thinking, text}, state) do
    send_to_frontend(state, text)
    {:noreply, state}
  end

  def handle_info({:agent_error, text}, state) do
    if state.frontend_pid do
      send(
        state.frontend_pid,
        {:cli_output, IO.ANSI.red() <> "[ERROR]: #{text}" <> IO.ANSI.reset()}
      )
    else
      Logger.error("[CLI Error (Detached)]: #{text}")
    end

    {:noreply, state}
  end

  defp send_to_frontend(state, text) do
    if state.frontend_pid do
      send(state.frontend_pid, {:cli_output, text})
    else
      Logger.info("[CLI Output (Detached)]: #{text}")
    end
  end
end
