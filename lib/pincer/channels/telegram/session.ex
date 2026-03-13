defmodule Pincer.Channels.Telegram.Session do
  @moduledoc """
  Driven Adapter for Telegram.
  One process per active chat that listens to PubSub and sends to the Telegram API.
  """
  use Pincer.Ports.Channel
  alias Pincer.Core.ProjectFlowDelivery
  alias Pincer.Core.ResponseEnvelope
  alias Pincer.Core.StatusDelivery
  alias Pincer.Core.SubAgentProgress
  alias Pincer.Core.StatusMessagePolicy
  alias Pincer.Core.StreamDelivery
  alias Pincer.Core.StreamingPolicy

  @preview_suppress_threshold 500

  @impl Pincer.Ports.Channel
  def start_link(%{chat_id: chat_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(chat_id))
  end

  def start_link(chat_id) do
    GenServer.start_link(__MODULE__, chat_id, name: via_tuple(chat_id))
  end

  defp via_tuple(chat_id),
    do: {:via, Registry, {Pincer.Core.Session.Registry, "telegram_session_worker_#{chat_id}"}}

  def ensure_started(chat_id, session_id \\ nil)

  def ensure_started(chat_id, session_id) do
    session_id = normalize_session_id(chat_id, session_id)

    case Registry.lookup(Pincer.Core.Session.Registry, "telegram_session_worker_#{chat_id}") do
      [] ->
        case Pincer.Channels.Telegram.SessionSupervisor.start_session(chat_id, session_id) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            GenServer.cast(pid, {:bind_session, session_id})
            {:error, {:already_started, pid}}

          {:error, _reason} = error ->
            error
        end

      [{pid, _value}] ->
        GenServer.cast(pid, {:bind_session, session_id})
        {:error, {:already_started, pid}}
    end
  end

  @impl true
  def init(%{chat_id: chat_id, session_id: session_id} = args)
      when is_binary(session_id) and session_id != "" do
    # 1. Macro init handles system:delivery
    super(args)

    # 2. Session-specific subscription
    subscribe_session(session_id)
    {:ok, state(chat_id, session_id)}
  end

  @impl true
  def init(chat_id) do
    session_id = default_session_id(chat_id)

    # 1. Macro init handles system:delivery
    super(chat_id)

    # 2. Session-specific subscription
    subscribe_session(session_id)
    {:ok, state(chat_id, session_id)}
  end

  # Hexagonal enforcement: override handles_session?
  @impl true
  def handles_session?(id),
    do: id == "telegram_" <> to_string(id) or String.starts_with?(id, "telegram_")

  @impl true
  def resolve_recipient(id) do
    case String.split(id, "_", parts: 2) do
      ["telegram", chat_id] -> chat_id
      _ -> id
    end
  end

  # We need to implement send_message/2 because the macro calls it
  @impl Pincer.Ports.Channel
  def send_message(chat_id, text) do
    Pincer.Channels.Telegram.send_message(chat_id, text)
  end

  @impl true
  def handle_cast({:bind_session, session_id}, state) when is_binary(session_id) do
    if state.session_id == session_id do
      {:noreply, state}
    else
      unsubscribe_session(state.session_id)
      subscribe_session(session_id)
      {:noreply, state(state.chat_id, session_id)}
    end
  end

  @impl true
  def handle_cast({:bind_session, _invalid_session_id}, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_partial, token}, state) do
    {:noreply,
     StreamDelivery.handle_partial(
       state,
       token,
       System.system_time(:millisecond),
       stream_transport(state, session_status(state.session_id)),
       suppress_preview?: &suppress_preview?/2
     )}
  end

  @impl true
  def handle_info({:agent_response, text, usage}, state) do
    session_status = session_status(state.session_id)

    text_with_usage =
      ResponseEnvelope.build(:telegram, text, usage, Map.get(session_status, :usage_display))

    if text_with_usage != "" do
      state =
        StreamDelivery.handle_final(
          state,
          text_with_usage,
          stream_transport(state, session_status)
        )

      maybe_advance_project_flow(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:agent_response, text}, state) do
    handle_info({:agent_response, text, nil}, state)
  end

  @impl true
  def handle_info({:agent_error, text}, state) do
    Pincer.Channels.Telegram.send_message(state.chat_id, "❌ <b>Agent Error</b>: #{text}")
    maybe_recover_project_flow(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_status, text}, state) do
    {:noreply, if(subagent_status?(text), do: state, else: deliver_status(state, text))}
  end

  @impl true
  def handle_info({:agent_thinking, _text}, state) do
    Telegex.send_chat_action(state.chat_id, "typing")
    {:noreply, state}
  end

  @impl true
  def handle_info({:subagent_progress, event}, state) do
    tracker = SubAgentProgress.apply_event(state.subagent_progress_tracker, event)
    dashboard = SubAgentProgress.render_dashboard(tracker)

    state =
      %{state | subagent_progress_tracker: tracker}
      |> deliver_subagent_dashboard(dashboard)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp session_status(session_id) do
    try do
      case Pincer.Core.Session.Server.get_status(session_id) do
        {:ok, status} when is_map(status) -> status
        _ -> %{}
      end
    catch
      :exit, _reason -> %{}
    end
  rescue
    _ -> %{}
  end

  defp stream_transport(state, session_status) do
    opts = ResponseEnvelope.delivery_options(:telegram, session_status)

    [
      send: fn text ->
        Pincer.Channels.Telegram.send_message(state.chat_id, text, opts)
      end,
      edit: fn message_id, text ->
        Pincer.Channels.Telegram.update_message(state.chat_id, message_id, text, opts)
      end
    ]
  end

  defp deliver_status(state, text) do
    Pincer.Channels.Telegram.send_message(state.chat_id, text)
    state
  end

  defp deliver_subagent_dashboard(state, nil), do: state

  defp deliver_subagent_dashboard(state, text) do
    StatusDelivery.deliver(
      state,
      text,
      send: fn content -> Pincer.Channels.Telegram.send_message(state.chat_id, content) end,
      edit: fn message_id, content ->
        Pincer.Channels.Telegram.update_message(state.chat_id, message_id, content)
      end
    )
  end

  defp maybe_advance_project_flow(state) do
    ProjectFlowDelivery.on_response(
      state.session_id,
      send_message: fn text -> Pincer.Channels.Telegram.send_message(state.chat_id, text) end
    )
  end

  defp maybe_recover_project_flow(state) do
    ProjectFlowDelivery.on_error(
      state.session_id,
      send_message: fn text -> Pincer.Channels.Telegram.send_message(state.chat_id, text) end
    )
  end

  defp subagent_status?(text) when is_binary(text) do
    String.contains?(text, "Sub-Agent")
  end

  defp subagent_status?(_), do: false

  defp default_session_id(chat_id), do: "telegram_#{chat_id}"

  defp normalize_session_id(_chat_id, session_id) when is_binary(session_id) and session_id != "",
    do: session_id

  defp normalize_session_id(chat_id, _), do: default_session_id(chat_id)

  defp subscribe_session(session_id), do: Pincer.Infra.PubSub.subscribe("session:#{session_id}")

  defp unsubscribe_session(session_id),
    do: Pincer.Infra.PubSub.unsubscribe("session:#{session_id}")

  defp state(chat_id, session_id) do
    Map.merge(
      Map.merge(
        %{
          chat_id: chat_id,
          session_id: session_id,
          preview_suppressed: false,
          subagent_progress_tracker: %{}
        },
        StatusMessagePolicy.initial_state()
      ),
      StreamingPolicy.initial_state()
    )
  end

  defp suppress_preview?(%{preview_suppressed: true}, _token), do: true

  defp suppress_preview?(state, token) do
    stream_state = StreamingPolicy.extract(state)

    is_nil(stream_state.message_id) and stream_state.buffer == "" and synthetic_partial?(token)
  end

  defp synthetic_partial?(token) do
    text = to_string(token)

    String.length(text) > @preview_suppress_threshold or
      Regex.match?(~r/<(thinking|thought)>.*?<\/(thinking|thought)>/is, text)
  end
end
