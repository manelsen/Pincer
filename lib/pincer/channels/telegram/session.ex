defmodule Pincer.Channels.Telegram.Session do
  @moduledoc """
  Driven Adapter for Telegram.
  One process per active chat that listens to PubSub and sends to the Telegram API.
  """
  use Pincer.Ports.Channel
  alias Pincer.Core.ProjectRouter
  alias Pincer.Core.SubAgentProgress
  alias Pincer.Core.StatusMessagePolicy
  alias Pincer.Core.StreamDelivery
  alias Pincer.Core.StreamingPolicy
  alias Pincer.Core.Session.Server

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
       stream_transport(state),
       suppress_preview?: &suppress_preview?/2
     )}
  end

  @impl true
  def handle_info({:agent_response, text, usage}, state) do
    display =
      try do
        case Pincer.Core.Session.Server.get_status(state.session_id) do
          {:ok, %{usage_display: d}} -> d
          _ -> "off"
        end
      catch
        :exit, _reason -> "off"
      end

    safe_text = text || ""
    usage_line = format_usage_line(usage, display)
    text_with_usage = safe_text <> usage_line

    if text_with_usage != "" do
      state = StreamDelivery.handle_final(state, text_with_usage, stream_transport(state))
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

  defp format_usage_line(nil, _display), do: ""
  defp format_usage_line(_usage, "off"), do: ""

  defp format_usage_line(usage, "tokens") do
    in_t = usage["prompt_tokens"] || 0
    out_t = usage["completion_tokens"] || 0
    "\n\n<i>📊 #{in_t} in · #{out_t} out</i>"
  end

  defp format_usage_line(usage, "full") do
    total = (usage["prompt_tokens"] || 0) + (usage["completion_tokens"] || 0)
    "\n\n<i>📊 total: #{total} tokens</i>"
  end

  defp send_opts_for_session(session_id) do
    try do
      case Pincer.Core.Session.Server.get_status(session_id) do
        {:ok, %{reasoning_visible: true}} -> [skip_reasoning_strip: true]
        _ -> []
      end
    catch
      :exit, _reason -> []
    end
  rescue
    _ -> []
  end

  defp stream_transport(state) do
    opts = send_opts_for_session(state.session_id)

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
    case StatusMessagePolicy.next_action(state, text) do
      :noop ->
        state

      {:send, text} ->
        case Pincer.Channels.Telegram.send_message(state.chat_id, text) do
          {:ok, message_id} -> StatusMessagePolicy.mark_sent(state, message_id, text)
          _ -> state
        end

      {:edit, message_id, text} ->
        case Pincer.Channels.Telegram.update_message(state.chat_id, message_id, text) do
          :ok ->
            StatusMessagePolicy.mark_edited(state, text)

          {:error, _reason} ->
            case Pincer.Channels.Telegram.send_message(state.chat_id, text) do
              {:ok, new_message_id} -> StatusMessagePolicy.mark_sent(state, new_message_id, text)
              _ -> state
            end
        end
    end
  end

  defp maybe_advance_project_flow(state) do
    case ProjectRouter.on_agent_response(state.session_id) do
      {:next, progress} ->
        Pincer.Channels.Telegram.send_message(
          state.chat_id,
          "Project Runner: #{progress.status_message}"
        )

        _ = Server.process_input(state.session_id, progress.prompt)
        :ok

      {:completed, progress} ->
        Pincer.Channels.Telegram.send_message(
          state.chat_id,
          "Project Runner: #{progress.status_message}"
        )

        :ok

      :noop ->
        :ok
    end
  end

  defp maybe_recover_project_flow(state) do
    case ProjectRouter.on_agent_error(state.session_id) do
      {:retry, progress} ->
        Pincer.Channels.Telegram.send_message(
          state.chat_id,
          "Project Runner: #{progress.status_message}"
        )

        _ = Server.process_input(state.session_id, progress.prompt)
        :ok

      {:paused, progress} ->
        Pincer.Channels.Telegram.send_message(
          state.chat_id,
          "Project Runner: #{progress.status_message}"
        )

        :ok

      :noop ->
        :ok
    end
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
