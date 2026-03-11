defmodule Pincer.Channels.Telegram.Session do
  @moduledoc """
  Driven Adapter for Telegram.
  One process per active chat that listens to PubSub and sends to the Telegram API.
  """
  use Pincer.Ports.Channel
  alias Pincer.Core.ProjectRouter
  alias Pincer.Core.SubAgentProgress
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
    if suppress_preview?(state, token) do
      {:noreply,
       state
       |> Map.put(:preview_suppressed, true)
       |> put_streaming_state(accumulate_partial(streaming_state(state), token))}
    else
      now = System.system_time(:millisecond)
      {stream_state, action} = StreamingPolicy.on_partial(streaming_state(state), token, now)

      state =
        case action do
          {:render_preview, preview_text} ->
            message_id =
              render_preview(
                state.chat_id,
                state.session_id,
                stream_state.message_id,
                preview_text
              )

            put_streaming_state(
              state,
              StreamingPolicy.mark_rendered(stream_state, message_id, now)
            )

          :noop ->
            put_streaming_state(state, stream_state)
        end

      {:noreply, state}
    end
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

    text_with_usage = text <> format_usage_line(usage, display)

    {stream_state, action} = StreamingPolicy.on_final(streaming_state(state), text_with_usage)
    deliver_final(state.chat_id, state.session_id, action)
    maybe_advance_project_flow(state)
    {:noreply, state |> Map.put(:preview_suppressed, false) |> put_streaming_state(stream_state)}
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

  defp render_preview(chat_id, session_id, nil, text) do
    case Pincer.Channels.Telegram.send_message(chat_id, text, send_opts_for_session(session_id)) do
      {:ok, mid} -> mid
      _ -> nil
    end
  end

  defp render_preview(chat_id, session_id, message_id, text) do
    case Pincer.Channels.Telegram.update_message(
           chat_id,
           message_id,
           text,
           send_opts_for_session(session_id)
         ) do
      :ok ->
        message_id

      {:error, _reason} ->
        case Pincer.Channels.Telegram.send_message(
               chat_id,
               text,
               send_opts_for_session(session_id)
             ) do
          {:ok, new_message_id} -> new_message_id
          _ -> nil
        end
    end
  end

  defp deliver_final(_chat_id, _session_id, :noop), do: :ok

  defp deliver_final(chat_id, session_id, {:send_final, text}) do
    Pincer.Channels.Telegram.send_message(chat_id, text, send_opts_for_session(session_id))
  end

  defp deliver_final(chat_id, session_id, {:edit_final, message_id, text}) do
    case Pincer.Channels.Telegram.update_message(
           chat_id,
           message_id,
           text,
           send_opts_for_session(session_id)
         ) do
      :ok ->
        :ok

      {:error, _reason} ->
        Pincer.Channels.Telegram.send_message(chat_id, text, send_opts_for_session(session_id))
    end
  end

  defp deliver_status(state, text) do
    Pincer.Channels.Telegram.send_message(state.chat_id, text)
    state
  end

  defp deliver_subagent_dashboard(state, nil), do: state

  defp deliver_subagent_dashboard(%{status_message_text: text} = state, text), do: state

  defp deliver_subagent_dashboard(%{status_message_id: nil} = state, text) do
    case Pincer.Channels.Telegram.send_message(state.chat_id, text) do
      {:ok, message_id} ->
        %{state | status_message_id: message_id, status_message_text: text}

      _ ->
        state
    end
  end

  defp deliver_subagent_dashboard(%{status_message_id: message_id} = state, text) do
    case Pincer.Channels.Telegram.update_message(state.chat_id, message_id, text) do
      :ok ->
        %{state | status_message_text: text}

      {:error, _reason} ->
        case Pincer.Channels.Telegram.send_message(state.chat_id, text) do
          {:ok, new_message_id} ->
            %{state | status_message_id: new_message_id, status_message_text: text}

          _ ->
            state
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

  defp streaming_state(state) do
    %{
      message_id: state.message_id,
      buffer: state.buffer,
      last_update: state.last_update
    }
  end

  defp put_streaming_state(state, stream_state) do
    %{
      state
      | message_id: stream_state.message_id,
        buffer: stream_state.buffer,
        last_update: stream_state.last_update
    }
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
      %{
        chat_id: chat_id,
        session_id: session_id,
        status_message_id: nil,
        status_message_text: nil,
        preview_suppressed: false,
        subagent_progress_tracker: %{}
      },
      StreamingPolicy.initial_state()
    )
  end

  defp suppress_preview?(%{preview_suppressed: true}, _token), do: true

  defp suppress_preview?(state, token) do
    stream_state = streaming_state(state)

    is_nil(stream_state.message_id) and stream_state.buffer == "" and synthetic_partial?(token)
  end

  defp synthetic_partial?(token) do
    text = to_string(token)

    String.length(text) > @preview_suppress_threshold or
      Regex.match?(~r/<(thinking|thought)>.*?<\/(thinking|thought)>/is, text)
  end

  defp accumulate_partial(stream_state, token) do
    %{stream_state | buffer: stream_state.buffer <> to_string(token)}
  end
end
