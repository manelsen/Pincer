defmodule Pincer.Channels.Telegram.Session do
  @moduledoc """
  Driven Adapter for Telegram.
  One process per active chat that listens to PubSub and sends to the Telegram API.
  """
  use GenServer
  require Logger
  alias Pincer.Core.ProjectRouter
  alias Pincer.Core.StreamingPolicy
  alias Pincer.Core.Session.Server

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
  def init(%{chat_id: chat_id, session_id: session_id})
      when is_binary(session_id) and session_id != "" do
    subscribe_session(session_id)
    {:ok, state(chat_id, session_id)}
  end

  @impl true
  def init(chat_id) do
    session_id = default_session_id(chat_id)
    subscribe_session(session_id)
    {:ok, state(chat_id, session_id)}
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
    now = System.system_time(:millisecond)
    {stream_state, action} = StreamingPolicy.on_partial(streaming_state(state), token, now)

    state =
      case action do
        {:render_preview, preview_text} ->
          message_id = render_preview(state.chat_id, stream_state.message_id, preview_text)

          put_streaming_state(state, StreamingPolicy.mark_rendered(stream_state, message_id, now))

        :noop ->
          put_streaming_state(state, stream_state)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_response, text}, state) do
    {stream_state, action} = StreamingPolicy.on_final(streaming_state(state), text)
    deliver_final(state.chat_id, action)
    maybe_advance_project_flow(state)
    {:noreply, put_streaming_state(state, stream_state)}
  end

  @impl true
  def handle_info({:agent_error, text}, state) do
    Pincer.Channels.Telegram.send_message(state.chat_id, "❌ <b>Agent Error</b>: #{text}")
    maybe_recover_project_flow(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_status, text}, state) do
    {:noreply, deliver_status(state, text)}
  end

  @impl true
  def handle_info({:agent_thinking, _text}, state) do
    Telegex.send_chat_action(state.chat_id, "typing")
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp render_preview(chat_id, nil, text) do
    case Pincer.Channels.Telegram.send_message(chat_id, text) do
      {:ok, mid} -> mid
      _ -> nil
    end
  end

  defp render_preview(chat_id, message_id, text) do
    case Pincer.Channels.Telegram.update_message(chat_id, message_id, text) do
      :ok ->
        message_id

      {:error, _reason} ->
        case Pincer.Channels.Telegram.send_message(chat_id, text) do
          {:ok, new_message_id} -> new_message_id
          _ -> nil
        end
    end
  end

  defp deliver_final(_chat_id, :noop), do: :ok

  defp deliver_final(chat_id, {:send_final, text}) do
    Pincer.Channels.Telegram.send_message(chat_id, text)
  end

  defp deliver_final(chat_id, {:edit_final, message_id, text}) do
    case Pincer.Channels.Telegram.update_message(chat_id, message_id, text) do
      :ok -> :ok
      {:error, _reason} -> Pincer.Channels.Telegram.send_message(chat_id, text)
    end
  end

  defp deliver_status(state, text) do
    if subagent_status?(text) do
      deliver_subagent_status(state, text)
    else
      Pincer.Channels.Telegram.send_message(state.chat_id, text)
      state
    end
  end

  defp deliver_subagent_status(%{status_message_id: nil} = state, text) do
    case Pincer.Channels.Telegram.send_message(state.chat_id, text) do
      {:ok, message_id} ->
        %{state | status_message_id: message_id, status_message_text: text}

      _ ->
        state
    end
  end

  defp deliver_subagent_status(
         %{status_message_id: _message_id, status_message_text: text} = state,
         text
       ) do
    state
  end

  defp deliver_subagent_status(%{status_message_id: message_id} = state, text) do
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
  defp unsubscribe_session(session_id), do: Pincer.Infra.PubSub.unsubscribe("session:#{session_id}")

  defp state(chat_id, session_id) do
    Map.merge(
      %{
        chat_id: chat_id,
        session_id: session_id,
        status_message_id: nil,
        status_message_text: nil
      },
      StreamingPolicy.initial_state()
    )
  end
end
