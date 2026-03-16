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

  ## Implementing a New Channel Session

  Use the `__using__` macro, which injects GenServer scaffolding **and**
  dispatches all session PubSub events to typed callbacks. Override only the
  callbacks you care about — the rest default to no-ops:

      defmodule Pincer.Channels.MyChannel.Session do
        use Pincer.Ports.Channel

        # Required: send text to the external API
        @impl Pincer.Ports.Channel
        def send_message(recipient_id, text) do
          MyAPI.send(recipient_id, text)
        end

        # Override only what you need
        @impl true
        def on_agent_response(text, _usage, state) do
          MyAPI.send(state.chat_id, text)
          state
        end
      end

  ## Session Callbacks

  All session callbacks receive the current GenServer state and **must return
  the (possibly updated) state**. The macro wraps the return value in
  `{:noreply, state}` automatically.

  | Callback | Triggered by |
  |---|---|
  | `on_agent_partial/2` | Streaming token chunk |
  | `on_agent_response/3` | Final LLM response |
  | `on_agent_error/2` | Executor error |
  | `on_agent_status/2` | Status / tool-use notification |
  | `on_agent_thinking/2` | LLM reasoning phase |
  | `on_subagent_progress/2` | Sub-agent progress event |
  | `on_approval_ui/3` | Tool approval request |

  All callbacks are optional — the default implementation is a no-op that
  returns the state unchanged.

  ## Transport Callbacks

  - `start_link/1` - Starts the channel process (required)
  - `send_message/2` - Sends a message to a recipient (optional)
  - `update_message/3` - Edits an existing message (optional)
  - `handles_session?/1` - Routes outbound messages (optional)
  - `resolve_recipient/1` - Maps session ID → external ID (optional)

  ## See Also

  - `Pincer.Channels.Telegram.Session` - Telegram implementation
  - `Pincer.Channels.Discord.Session` - Discord implementation
  - `Pincer.Channels.Factory` - Channel instantiation logic
  """

  # ---------------------------------------------------------------------------
  # Transport callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Starts the channel process with the given configuration.
  """
  @callback start_link(config :: map()) :: GenServer.on_start()

  @doc """
  Sends a message to a recipient through this channel.
  """
  @callback send_message(recipient_id :: String.t(), content :: String.t()) ::
              :ok | {:ok, any()} | {:error, any()}

  @doc """
  Updates an existing message sent via this channel. Useful for streaming.
  """
  @callback update_message(recipient_id :: String.t(), message_id :: any(), content :: String.t()) ::
              :ok | {:error, any()}

  @doc """
  Checks if a given session ID belongs to this channel adapter.
  """
  @callback handles_session?(session_id :: String.t()) :: boolean()

  @doc """
  Resolves the external recipient identifier from a session ID.
  """
  @callback resolve_recipient(session_id :: String.t()) :: String.t()

  # ---------------------------------------------------------------------------
  # Session PubSub callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Called when a streaming token chunk arrives. Return the updated state.
  """
  @callback on_agent_partial(token :: any(), state :: map()) :: map()

  @doc """
  Called when the executor emits a final response. Return the updated state.
  `usage` is `nil` when no token accounting is available.
  """
  @callback on_agent_response(text :: String.t(), usage :: map() | nil, state :: map()) :: map()

  @doc """
  Called when the executor reports an error. Return the updated state.
  """
  @callback on_agent_error(text :: String.t(), state :: map()) :: map()

  @doc """
  Called for status / tool-use notifications. Return the updated state.
  """
  @callback on_agent_status(text :: String.t(), state :: map()) :: map()

  @doc """
  Called during the LLM reasoning / thinking phase. Return the updated state.
  """
  @callback on_agent_thinking(text :: any(), state :: map()) :: map()

  @doc """
  Called when a sub-agent emits a progress event. Return the updated state.
  """
  @callback on_subagent_progress(event :: any(), state :: map()) :: map()

  @doc """
  Called when a tool requires user approval. Return the updated state.
  """
  @callback on_approval_ui(call_id :: any(), command :: String.t(), state :: map()) :: map()

  @optional_callbacks send_message: 2,
                      update_message: 3,
                      handles_session?: 1,
                      resolve_recipient: 1,
                      on_agent_partial: 2,
                      on_agent_response: 3,
                      on_agent_error: 2,
                      on_agent_status: 2,
                      on_agent_thinking: 2,
                      on_subagent_progress: 2,
                      on_approval_ui: 3

  # ---------------------------------------------------------------------------
  # __using__ macro
  # ---------------------------------------------------------------------------

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Pincer.Ports.Channel
      use GenServer
      require Logger
      alias Pincer.Infra.PubSub

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      def init(state) do
        PubSub.subscribe("system:delivery")
        {:ok, state}
      end

      # --- Outbound delivery via system:delivery PubSub ---

      @impl GenServer
      def handle_info({:deliver_message, session_id, message}, state) do
        if handles_session?(session_id) do
          recipient_id = resolve_recipient(session_id)

          if function_exported?(__MODULE__, :send_message, 2) do
            apply(__MODULE__, :send_message, [recipient_id, message])
          end
        end

        {:noreply, state}
      end

      # --- Session PubSub event dispatch → typed callbacks ---

      @impl GenServer
      def handle_info({:agent_partial, token}, state),
        do: {:noreply, on_agent_partial(token, state)}

      @impl GenServer
      def handle_info({:agent_response, text, usage}, state),
        do: {:noreply, on_agent_response(text, usage, state)}

      @impl GenServer
      def handle_info({:agent_response, text}, state),
        do: {:noreply, on_agent_response(text, nil, state)}

      @impl GenServer
      def handle_info({:agent_error, text}, state),
        do: {:noreply, on_agent_error(text, state)}

      @impl GenServer
      def handle_info({:agent_status, text}, state),
        do: {:noreply, on_agent_status(text, state)}

      @impl GenServer
      def handle_info({:agent_thinking, text}, state),
        do: {:noreply, on_agent_thinking(text, state)}

      @impl GenServer
      def handle_info({:subagent_progress, event}, state),
        do: {:noreply, on_subagent_progress(event, state)}

      @impl GenServer
      def handle_info({:approval_ui, call_id, command}, state),
        do: {:noreply, on_approval_ui(call_id, command, state)}

      @impl GenServer
      def handle_info(_other, state), do: {:noreply, state}

      # --- Default no-op callback implementations ---

      def on_agent_partial(_token, state), do: state
      def on_agent_response(_text, _usage, state), do: state
      def on_agent_error(_text, state), do: state
      def on_agent_status(_text, state), do: state
      def on_agent_thinking(_text, state), do: state
      def on_subagent_progress(_event, state), do: state
      def on_approval_ui(_call_id, _command, state), do: state

      # --- Default routing helpers ---

      def handles_session?(session_id) do
        prefix =
          __MODULE__
          |> Module.split()
          |> List.last()
          |> String.downcase()

        String.starts_with?(session_id, prefix <> "_")
      end

      def resolve_recipient(session_id) do
        case String.split(session_id, "_", parts: 2) do
          [_prefix, recipient] -> recipient
          _ -> session_id
        end
      end

      defoverridable start_link: 1,
                     init: 1,
                     handle_info: 2,
                     handles_session?: 1,
                     resolve_recipient: 1,
                     on_agent_partial: 2,
                     on_agent_response: 3,
                     on_agent_error: 2,
                     on_agent_status: 2,
                     on_agent_thinking: 2,
                     on_subagent_progress: 2,
                     on_approval_ui: 3
    end
  end
end
