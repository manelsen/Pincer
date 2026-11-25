defmodule Pincer.Channels.Feishu.Session do
  @moduledoc """
  Feishu channel session GenServer.

  One process per active Feishu user conversation. Subscribes to PubSub events
  for the session and handles agent callbacks (partial, response, error).

  ## Card Streaming

  Feishu supports interactive cards that can be updated in-place via
  `Pincer.Channels.Feishu.API.update_card/2`. The streaming pattern:

  - `on_agent_partial/2` -- Sends an interactive card message on the first
    token, then updates it in-place on subsequent tokens.
  - `on_agent_response/3` -- Sends the final complete message as plain text.
  - `on_agent_error/2` -- Sends error text to the user.

  ## API Module Injection

  The Feishu API module is resolved via application config to allow test
  mocking without external dependencies:

    - `:feishu_api_module` -- defaults to `Pincer.Channels.Feishu.API`

  ## See Also

  - `Pincer.Channels.Feishu` - Channel supervisor and webhook handler
  - `Pincer.Channels.Feishu.API` - Feishu HTTP API client
  - `Pincer.Channels.Feishu.Cards` - Card payload construction
  """

  use PincerPorts.Channel
  alias Pincer.Channels.Feishu.Cards
  alias Pincer.Channels.Shared.SessionBridge

  @impl PincerPorts.Channel
  def start_link(%{chat_id: chat_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(chat_id))
  end

  @spec ensure_started(String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(chat_id, session_id) do
    SessionBridge.ensure_started({:feishu, chat_id},
      session_id: session_id,
      start_worker: &Pincer.Channels.Feishu.SessionSupervisor.start_session/2,
      already_started: :ok
    )
  end

  @impl true
  def init(%{chat_id: chat_id} = args) do
    session_id = Map.get(args, :session_id, SessionBridge.default_session_id(:feishu, chat_id))
    super(args)
    SessionBridge.subscribe(session_id)
    {:ok, initial_state(chat_id, session_id)}
  end

  @impl PincerPorts.Channel
  def handles_session?(id), do: SessionBridge.handles_session?(:feishu, id)

  @impl PincerPorts.Channel
  def resolve_recipient(id), do: SessionBridge.resolve_recipient(:feishu, id)

  @impl PincerPorts.Channel
  def send_message(chat_id, text) do
    Pincer.Channels.Feishu.send_message(chat_id, text)
  end

  # --- Session PubSub callbacks ---

  @impl true
  def handle_cast({:bind_session, session_id}, state) do
    SessionBridge.bind_session(state, session_id)
  end

  @impl true
  def on_agent_partial(token, state) do
    chunk = to_string(token)

    case state.card_ref do
      nil ->
        # First token: send an interactive card message
        card = Cards.create_card(chunk)
        content = Jason.encode!(card)

        case feishu_api().send_message(state.chat_id, content, "interactive") do
          {:ok, %{"message_id" => message_id}} ->
            %{state | card_ref: message_id, buffer: chunk}

          _ ->
            # Card creation failed; accumulate in buffer as fallback
            %{state | buffer: state.buffer <> chunk}
        end

      card_ref ->
        # Subsequent tokens: update the existing card in-place
        new_buffer = state.buffer <> chunk
        updated_card = Cards.update_card_content(Cards.create_card(new_buffer), new_buffer)

        feishu_api().update_card(card_ref, updated_card)
        %{state | buffer: new_buffer}
    end
  end

  @impl true
  def on_agent_response(text, _usage, state) do
    unless text == "" do
      content = Jason.encode!(%{"text" => text})
      feishu_api().send_message(state.chat_id, content, "text")
    end

    %{state | buffer: "", card_ref: nil}
  end

  @impl true
  def on_agent_error(text, state) do
    content = Jason.encode!(%{"text" => "[Error] #{text}"})
    feishu_api().send_message(state.chat_id, content, "text")
    %{state | buffer: "", card_ref: nil}
  end

  # --- Private helpers ---

  defp feishu_api do
    Application.get_env(:pincer, :feishu_api_module, Pincer.Channels.Feishu.API)
  end

  defp via_tuple(chat_id), do: SessionBridge.via_tuple(:feishu, chat_id)

  defp initial_state(chat_id, session_id) do
    SessionBridge.initial_state(%{
      chat_id: chat_id,
      session_id: session_id,
      buffer: "",
      card_ref: nil
    })
  end
end
