defmodule Pincer.Channels.WhatsApp.Session do
  @moduledoc """
  WhatsApp session worker that forwards session PubSub events to a chat ID.
  """
  use PincerPorts.Channel
  alias Pincer.Channels.Shared.SessionBridge

  @impl PincerPorts.Channel
  def start_link(%{chat_id: chat_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(chat_id))
  end

  def start_link(chat_id) do
    GenServer.start_link(__MODULE__, chat_id, name: via_tuple(chat_id))
  end

  defp via_tuple(chat_id), do: SessionBridge.via_tuple(:whatsapp, chat_id)

  def ensure_started(chat_id, session_id \\ nil)

  def ensure_started(chat_id, session_id) do
    SessionBridge.ensure_started({:whatsapp, chat_id},
      session_id: session_id,
      start_worker: &Pincer.Channels.WhatsApp.SessionSupervisor.start_session/2,
      already_started: :error
    )
  end

  @impl true
  def init(%{chat_id: chat_id, session_id: session_id} = args)
      when is_binary(session_id) and session_id != "" do
    super(args)
    SessionBridge.subscribe(session_id)
    {:ok, SessionBridge.initial_state(%{chat_id: chat_id, session_id: session_id})}
  end

  @impl true
  def init(chat_id) do
    session_id = SessionBridge.default_session_id(:whatsapp, chat_id)
    super(chat_id)
    SessionBridge.subscribe(session_id)
    {:ok, SessionBridge.initial_state(%{chat_id: chat_id, session_id: session_id})}
  end

  @impl PincerPorts.Channel
  def handles_session?(id), do: SessionBridge.handles_session?(:whatsapp, id)

  @impl PincerPorts.Channel
  def resolve_recipient(id), do: SessionBridge.resolve_recipient(:whatsapp, id)

  @impl PincerPorts.Channel
  def send_message(chat_id, text) do
    Pincer.Channels.WhatsApp.send_message(chat_id, text)
  end

  # --- Session bind ---

  @impl true
  def handle_cast({:bind_session, session_id}, state) do
    SessionBridge.bind_session(state, session_id)
  end

  # --- Session PubSub callbacks ---

  @impl true
  def on_agent_response(text, _usage, state) do
    Pincer.Channels.WhatsApp.send_message(state.chat_id, text)
    maybe_advance_project_flow(state)
    state
  end

  @impl true
  def on_agent_error(text, state) do
    Pincer.Channels.WhatsApp.send_message(
      state.chat_id,
      PincerPorts.ChannelPolicy.error_message(:whatsapp, text)
    )

    maybe_recover_project_flow(state)
    state
  end

  @impl true
  def on_agent_status(text, state) do
    Pincer.Channels.WhatsApp.send_message(state.chat_id, text)
    state
  end

  # on_agent_partial → no-op (macro default)
  # on_agent_thinking → no-op (macro default)
  # on_subagent_progress → no-op (macro default)
  # on_approval_ui → no-op (macro default)

  # --- Private helpers ---

  defp maybe_advance_project_flow(state) do
    PincerPorts.Project.on_agent_response(
      state.session_id,
      send_message: fn text -> Pincer.Channels.WhatsApp.send_message(state.chat_id, text) end
    )
  end

  defp maybe_recover_project_flow(state) do
    PincerPorts.Project.on_agent_error(
      state.session_id,
      send_message: fn text -> Pincer.Channels.WhatsApp.send_message(state.chat_id, text) end
    )
  end
end
