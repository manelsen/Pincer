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

  use Pincer.Ports.Channel

  @impl Pincer.Ports.Channel
  def start_link(_config) do
    GenServer.start_link(__MODULE__, %{frontend_pid: nil}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Logger.info("CLI Channel Enabled.")
    # We still need session-specific subscription for direct agent events (thinking, etc)
    Pincer.Infra.PubSub.subscribe("session:cli_user")

    # Macro init handles "system:delivery"
    super(state)
  end

  # We override handles_session? because CLI uses a fixed "cli_user" ID
  @impl true
  def handles_session?("cli_user"), do: true
  def handles_session?(_), do: false

  @impl true
  def resolve_recipient("cli_user"), do: "cli_user"
  def resolve_recipient(id), do: id

  @impl GenServer
  def handle_call(:attach, {from_pid, _tag}, state) do
    case Registry.lookup(Pincer.Core.Session.Registry, "cli_user") do
      [{_, _}] -> :ok
      [] -> Pincer.Core.Session.Server.start_link(session_id: "cli_user")
    end

    {:reply, :ok, %{state | frontend_pid: from_pid}}
  end

  @doc """
  Sends a message to the CLI frontend.

  This implements the `Pincer.Ports.Channel.send_message/2` callback. The message
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
  @impl Pincer.Ports.Channel
  def send_message(_chat_id, text) do
    GenServer.cast(__MODULE__, {:dispatch, text})
    :ok
  end

  alias Pincer.Core.Structs.IncomingMessage

  @doc false
  @impl true
  def handle_cast({:user_input, text}, state) do
    incoming = IncomingMessage.new("cli_user", text)
    Pincer.Core.Session.Server.process_input("cli_user", incoming)
    {:noreply, state}
  end

  def handle_cast({:dispatch, text}, state) do
    send_to_frontend(state, text)
    {:noreply, state}
  end

  # The macro now handles handle_info({:deliver_message, ...}) by calling send_message/2

  def handle_info({:agent_response, text, _usage}, state) do
    if text && text != "", do: send_to_frontend(state, text)
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_response, text}, state) do
    handle_info({:agent_response, text, nil}, state)
  end

  def handle_info({:agent_status, text}, state) do
    if text && text != "", do: send_to_frontend(state, text)
    {:noreply, state}
  end

  def handle_info({:agent_thinking, text}, state) do
    if text && text != "", do: send_to_frontend(state, text)
    {:noreply, state}
  end

  def handle_info({:agent_error, text}, state) do
    if text && text != "" do
      if state.frontend_pid do
        send(
          state.frontend_pid,
          {:cli_output, IO.ANSI.red() <> "[ERROR]: #{text}" <> IO.ANSI.reset()}
        )
      else
        Logger.error("[CLI Error (Detached)]: #{text}")
      end
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
