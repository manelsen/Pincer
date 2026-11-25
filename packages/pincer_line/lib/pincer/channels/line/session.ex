defmodule Pincer.Channels.Line.Session do
  @moduledoc """
  LINE channel session GenServer.

  One process per active LINE user. Subscribes to PubSub events for the
  session and handles agent callbacks (partial, response, error).

  ## Chunked Streaming

  LINE has no message edit API, so streaming is implemented via chunked
  push messages. Partial text is accumulated in a buffer and flushed:
  - On sentence boundaries (`.`, `!`, `?` followed by space or end)
  - When the buffer exceeds `@chunk_size` characters (default 500)

  ## API Module Injection

  The LINE API module is resolved via `Application.get_env(:pincer, :line_api_module)`
  to allow test mocking without external dependencies.

  ## See Also

  - `Pincer.Channels.Line` - Channel supervisor and webhook handler
  - `Pincer.Channels.Line.API` - LINE Messaging API client
  """

  use PincerPorts.Channel
  alias Pincer.Channels.Shared.{Chunking, SessionBridge}
  @chunk_size 500

  @impl PincerPorts.Channel
  def start_link(%{chat_id: chat_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(chat_id))
  end

  @spec ensure_started(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(chat_id, session_id) do
    SessionBridge.ensure_started({:line, chat_id},
      session_id: session_id,
      start_worker: &Pincer.Channels.Line.SessionSupervisor.start_session/2,
      already_started: :ok
    )
  end

  @impl true
  def init(%{chat_id: chat_id} = args) do
    session_id = Map.get(args, :session_id, SessionBridge.default_session_id(:line, chat_id))
    super(args)
    SessionBridge.subscribe(session_id)
    {:ok, initial_state(chat_id, session_id)}
  end

  @impl PincerPorts.Channel
  def handles_session?(id), do: SessionBridge.handles_session?(:line, id)

  @impl PincerPorts.Channel
  def resolve_recipient(id), do: SessionBridge.resolve_recipient(:line, id)

  @impl PincerPorts.Channel
  def send_message(chat_id, text) do
    Pincer.Channels.Line.send_message(chat_id, text)
  end

  @impl true
  def handle_cast({:bind_session, session_id}, state) do
    SessionBridge.bind_session(state, session_id)
  end

  # --- Session PubSub callbacks ---

  @impl true
  def on_agent_partial(token, state) do
    case Chunking.append_stream_buffer(state.buffer, token, max_bytes: @chunk_size) do
      {:flush, payload, empty_buffer} ->
        state = flush_buffer(state, payload)
        %{state | buffer: empty_buffer}

      {:buffer, new_buffer} ->
        %{state | buffer: new_buffer}
    end
  end

  @impl true
  def on_agent_response(text, _usage, state) do
    # Flush any pending buffer first
    state = maybe_flush_buffer(state)

    unless text == "" do
      line_api().push_message(state.chat_id, [
        %{"type" => "text", "text" => text}
      ])
    end

    state
  end

  @impl true
  def on_agent_error(text, state) do
    # Flush any pending buffer first
    state = maybe_flush_buffer(state)

    line_api().push_message(state.chat_id, [
      %{"type" => "text", "text" => "[Error] #{text}"}
    ])

    %{state | buffer: ""}
  end

  # --- Private helpers ---

  defp flush_buffer(state, buffer) do
    line_api().push_message(state.chat_id, [
      %{"type" => "text", "text" => buffer}
    ])

    %{state | buffer: ""}
  end

  defp maybe_flush_buffer(%{buffer: ""} = state), do: state

  defp maybe_flush_buffer(state) do
    flush_buffer(state, state.buffer)
  end

  defp line_api do
    Application.get_env(:pincer, :line_api_module, Pincer.Channels.Line.API)
  end

  defp via_tuple(chat_id), do: SessionBridge.via_tuple(:line, chat_id)

  defp initial_state(chat_id, session_id) do
    SessionBridge.initial_state(%{
      chat_id: chat_id,
      session_id: session_id,
      buffer: ""
    })
  end
end
