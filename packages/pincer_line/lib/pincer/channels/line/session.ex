defmodule Pincer.Channels.Line.Session do
  @compile {:no_warn_undefined, [
    Pincer.Core.Session.Registry,
    Pincer.Infra.PubSub
  ]}
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

  use Pincer.Ports.Channel
  require Logger

  @chunk_size 500

  # Sentence-ending punctuation followed by whitespace or end-of-string
  @sentence_boundary ~r/[.!?](\s|$)/

  @impl Pincer.Ports.Channel
  def start_link(%{chat_id: chat_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(chat_id))
  end

  @impl true
  def init(%{chat_id: chat_id} = args) do
    session_id = Map.get(args, :session_id, "line_#{chat_id}")
    super(args)
    subscribe_session(session_id)
    {:ok, initial_state(chat_id, session_id)}
  end

  @impl Pincer.Ports.Channel
  def handles_session?(id) do
    String.starts_with?(id, "line_")
  end

  @impl Pincer.Ports.Channel
  def resolve_recipient(id) do
    case String.split(id, "_", parts: 2) do
      ["line", user_id] -> user_id
      _ -> id
    end
  end

  @impl Pincer.Ports.Channel
  def send_message(chat_id, text) do
    Pincer.Channels.Line.send_message(chat_id, text)
  end

  # --- Session PubSub callbacks ---

  @impl true
  def on_agent_partial(token, state) do
    chunk = to_string(token)
    new_buffer = state.buffer <> chunk

    if should_flush?(new_buffer) do
      flush_buffer(state, new_buffer)
    else
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

  defp should_flush?(buffer) do
    byte_size(buffer) > @chunk_size or Regex.match?(@sentence_boundary, buffer)
  end

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

  defp via_tuple(chat_id) do
    {:via, Registry, {Pincer.Core.Session.Registry, "line_session_worker_#{chat_id}"}}
  end

  defp subscribe_session(session_id) do
    Pincer.Infra.PubSub.subscribe("session:#{session_id}")
  end

  defp initial_state(chat_id, session_id) do
    %{
      chat_id: chat_id,
      session_id: session_id,
      buffer: ""
    }
  end
end
