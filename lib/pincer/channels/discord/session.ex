defmodule Pincer.Channels.Discord.Session do
  @moduledoc """
  Driven Adapter for Discord.
  One process per active Discord channel that listens to PubSub and sends messages via Nostrum.
  """
  use Pincer.Ports.Channel
  alias Pincer.Core.ProjectRouter
  alias Pincer.Core.StreamingPolicy
  alias Pincer.Core.Session.Server

  @impl Pincer.Ports.Channel
  def start_link(%{channel_id: channel_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(channel_id))
  end

  def start_link(channel_id) do
    GenServer.start_link(__MODULE__, channel_id, name: via_tuple(channel_id))
  end

  defp via_tuple(channel_id),
    do: {:via, Registry, {Pincer.Core.Session.Registry, "discord_session_worker_#{channel_id}"}}

  def ensure_started(channel_id, session_id \\ nil)

  def ensure_started(channel_id, session_id) do
    session_id = normalize_session_id(channel_id, session_id)

    case Registry.lookup(Pincer.Core.Session.Registry, "discord_session_worker_#{channel_id}") do
      [] ->
        case Pincer.Channels.Discord.SessionSupervisor.start_session(channel_id, session_id) do
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
  def init(%{channel_id: channel_id, session_id: session_id} = args)
      when is_binary(session_id) and session_id != "" do
    # 1. Macro init handles system:delivery
    super(args)

    # 2. Session-specific subscription
    subscribe_session(session_id)
    Logger.info("[DISCORD SESSION] Worker started for channel: #{channel_id}")
    {:ok, state(channel_id, session_id)}
  end

  @impl true
  def init(channel_id) do
    session_id = default_session_id(channel_id)
    
    # 1. Macro init handles system:delivery
    super(channel_id)

    # 2. Session-specific subscription
    subscribe_session(session_id)
    Logger.info("[DISCORD SESSION] Worker started for channel: #{channel_id}")
    {:ok, state(channel_id, session_id)}
  end

  # Hexagonal enforcement: override handles_session?
  @impl true
  def handles_session?(id), do: String.starts_with?(id, "discord_")

  @impl true
  def resolve_recipient(id) do
    case String.split(id, "_", parts: 2) do
      ["discord", channel_id] -> channel_id
      _ -> id
    end
  end

  # We need to implement send_message/2 because the macro calls it
  @impl Pincer.Ports.Channel
  def send_message(channel_id, text) do
    Pincer.Channels.Discord.send_message(channel_id, text)
  end

  @impl true
  def handle_cast({:bind_session, session_id}, state) when is_binary(session_id) do
    if state.session_id == session_id do
      {:noreply, state}
    else
      unsubscribe_session(state.session_id)
      subscribe_session(session_id)
      {:noreply, state(state.channel_id, session_id)}
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
          message_id = render_preview(state.channel_id, stream_state.message_id, preview_text)

          put_streaming_state(state, StreamingPolicy.mark_rendered(stream_state, message_id, now))

        :noop ->
          put_streaming_state(state, stream_state)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_response, text, _usage}, state) do
    {stream_state, action} = StreamingPolicy.on_final(streaming_state(state), text)
    deliver_final(state.channel_id, action)
    maybe_advance_project_flow(state)
    {:noreply, put_streaming_state(state, stream_state)}
  end

  @impl true
  def handle_info({:agent_response, text}, state) do
    handle_info({:agent_response, text, nil}, state)
  end

  @impl true
  def handle_info({:agent_error, text}, state) do
    Pincer.Channels.Discord.send_message("#{state.channel_id}", "❌ **Agent Error**: #{text}")
    maybe_recover_project_flow(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_status, text}, state) do
    {:noreply, deliver_status(state, text)}
  end

  @impl true
  def handle_info({:agent_thinking, text}, state) do
    # For now, we just log it to avoid spamming the channel with "thinking" messages
    Logger.debug("[DISCORD SESSION] Agent thinking: #{text}")
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp render_preview(channel_id, nil, text) do
    case Pincer.Channels.Discord.send_message("#{channel_id}", text) do
      {:ok, mid} -> mid
      _ -> nil
    end
  end

  defp render_preview(channel_id, message_id, text) do
    case Pincer.Channels.Discord.update_message("#{channel_id}", message_id, text) do
      :ok ->
        message_id

      {:error, _reason} ->
        case Pincer.Channels.Discord.send_message("#{channel_id}", text) do
          {:ok, new_message_id} -> new_message_id
          _ -> nil
        end
    end
  end

  defp deliver_final(_channel_id, :noop), do: :ok

  defp deliver_final(channel_id, {:send_final, text}) do
    Pincer.Channels.Discord.send_message("#{channel_id}", text)
  end

  defp deliver_final(channel_id, {:edit_final, message_id, text}) do
    case Pincer.Channels.Discord.update_message("#{channel_id}", message_id, text) do
      :ok -> :ok
      {:error, _reason} -> Pincer.Channels.Discord.send_message("#{channel_id}", text)
    end
  end

  defp deliver_status(state, text) do
    if subagent_status?(text) do
      deliver_subagent_status(state, text)
    else
      Pincer.Channels.Discord.send_message("#{state.channel_id}", text)
      state
    end
  end

  defp deliver_subagent_status(%{status_message_id: nil} = state, text) do
    case Pincer.Channels.Discord.send_message("#{state.channel_id}", text) do
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
    case Pincer.Channels.Discord.update_message("#{state.channel_id}", message_id, text) do
      :ok ->
        %{state | status_message_text: text}

      {:error, _reason} ->
        case Pincer.Channels.Discord.send_message("#{state.channel_id}", text) do
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
        Pincer.Channels.Discord.send_message(
          "#{state.channel_id}",
          "Project Runner: #{progress.status_message}"
        )

        _ = Server.process_input(state.session_id, progress.prompt)
        :ok

      {:completed, progress} ->
        Pincer.Channels.Discord.send_message(
          "#{state.channel_id}",
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
        Pincer.Channels.Discord.send_message(
          "#{state.channel_id}",
          "Project Runner: #{progress.status_message}"
        )

        _ = Server.process_input(state.session_id, progress.prompt)
        :ok

      {:paused, progress} ->
        Pincer.Channels.Discord.send_message(
          "#{state.channel_id}",
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

  defp default_session_id(channel_id), do: "discord_#{channel_id}"

  defp normalize_session_id(_channel_id, session_id)
       when is_binary(session_id) and session_id != "",
       do: session_id

  defp normalize_session_id(channel_id, _), do: default_session_id(channel_id)

  defp subscribe_session(session_id), do: Pincer.Infra.PubSub.subscribe("session:#{session_id}")
  defp unsubscribe_session(session_id), do: Pincer.Infra.PubSub.unsubscribe("session:#{session_id}")

  defp state(channel_id, session_id) do
    Map.merge(
      %{
        channel_id: channel_id,
        session_id: session_id,
        status_message_id: nil,
        status_message_text: nil
      },
      StreamingPolicy.initial_state()
    )
  end
end
