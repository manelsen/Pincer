defmodule Pincer.Channels.DingTalk.Session do
  @moduledoc """
  DingTalk channel session GenServer.

  One process per active DingTalk user. Subscribes to PubSub events for the
  session and handles agent callbacks (partial, response, error).

  ## Card Streaming

  Unlike LINE (which has no edit API), DingTalk supports interactive cards
  that can be updated in-place. The streaming pattern works as follows:

  - `on_agent_partial/2` -- Creates a card on the first token, then updates
    it on subsequent tokens.
  - `on_agent_response/3` -- Sends the final message via `send_dm/3` or
    `send_group/3`.
  - `on_agent_error/2` -- Sends error text to the user.

  ## API Module Injection

  The DingTalk API and channel modules are resolved via application config
  to allow test mocking without external dependencies:

    - `:dingtalk_api_module` -- defaults to `DingTalk.API`
    - `:dingtalk_channel_module` -- defaults to `DingTalk` channel

  ## See Also

  - `Pincer.Channels.DingTalk` - Channel supervisor and webhook handler
  - `Pincer.Channels.DingTalk.API` - DingTalk HTTP API client
  """

  use Pincer.Ports.Channel
  require Logger

  @impl Pincer.Ports.Channel
  def start_link(%{chat_id: chat_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(chat_id))
  end

  @impl true
  def init(%{chat_id: chat_id} = args) do
    session_id = Map.get(args, :session_id, "dingtalk_#{chat_id}")
    super(args)
    subscribe_session(session_id)
    {:ok, initial_state(chat_id, session_id)}
  end

  @impl Pincer.Ports.Channel
  def handles_session?(id) do
    String.starts_with?(id, "dingtalk_")
  end

  @impl Pincer.Ports.Channel
  def resolve_recipient(id) do
    case String.split(id, "_", parts: 2) do
      ["dingtalk", staff_id] -> staff_id
      _ -> id
    end
  end

  @impl Pincer.Ports.Channel
  def send_message(chat_id, text) do
    dingtalk_channel().send_message(chat_id, text)
  end

  # --- Session PubSub callbacks ---

  @impl true
  def on_agent_partial(token, state) do
    chunk = to_string(token)

    case state.card_ref do
      nil ->
        # First token: create a new card
        card_content = %{"content" => chunk}

        case dingtalk_api().create_card(card_content, %{"cardTemplateId" => "streaming"}) do
          {:ok, %{"cardInstanceId" => card_id}} ->
            %{state | card_ref: card_id}

          _ ->
            # Card creation failed; accumulate in buffer
            %{state | buffer: state.buffer <> chunk}
        end

      ref ->
        # Subsequent tokens: update the existing card
        new_content = %{"content" => state.buffer <> chunk}

        dingtalk_api().update_card(ref, new_content)
        %{state | buffer: state.buffer <> chunk}
    end
  end

  @impl true
  def on_agent_response(text, _usage, state) do
    unless text == "" do
      dingtalk_channel().send_message(state.chat_id, text)
    end

    %{state | buffer: "", card_ref: nil}
  end

  @impl true
  def on_agent_error(text, state) do
    dingtalk_channel().send_message(state.chat_id, "[Error] #{text}")
    %{state | buffer: "", card_ref: nil}
  end

  # --- Private helpers ---

  defp dingtalk_api do
    Application.get_env(:pincer, :dingtalk_api_module, Pincer.Channels.DingTalk.API)
  end

  defp dingtalk_channel do
    Application.get_env(:pincer, :dingtalk_channel_module, Pincer.Channels.DingTalk)
  end

  defp via_tuple(chat_id) do
    {:via, Registry, {Pincer.Core.Session.Registry, "dingtalk_session_worker_#{chat_id}"}}
  end

  defp subscribe_session(session_id) do
    Pincer.Infra.PubSub.subscribe("session:#{session_id}")
  end

  defp initial_state(chat_id, session_id) do
    %{
      chat_id: chat_id,
      session_id: session_id,
      buffer: "",
      card_ref: nil
    }
  end
end
