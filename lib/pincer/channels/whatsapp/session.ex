defmodule Pincer.Channels.WhatsApp.Session do
  @moduledoc """
  WhatsApp session worker that forwards session PubSub events to a chat ID.
  """

  use GenServer
  alias Pincer.Core.ProjectRouter
  alias Pincer.Session.Server

  def start_link(%{chat_id: chat_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(chat_id))
  end

  def start_link(chat_id) do
    GenServer.start_link(__MODULE__, chat_id, name: via_tuple(chat_id))
  end

  defp via_tuple(chat_id),
    do: {:via, Registry, {Pincer.Session.Registry, "whatsapp_session_worker_#{chat_id}"}}

  def ensure_started(chat_id, session_id \\ nil)

  def ensure_started(chat_id, session_id) do
    session_id = normalize_session_id(chat_id, session_id)

    case Registry.lookup(Pincer.Session.Registry, "whatsapp_session_worker_#{chat_id}") do
      [] ->
        case Pincer.Channels.WhatsApp.SessionSupervisor.start_session(chat_id, session_id) do
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
    {:ok, %{chat_id: chat_id, session_id: session_id}}
  end

  @impl true
  def init(chat_id) do
    session_id = default_session_id(chat_id)
    subscribe_session(session_id)
    {:ok, %{chat_id: chat_id, session_id: session_id}}
  end

  @impl true
  def handle_cast({:bind_session, session_id}, state) when is_binary(session_id) do
    if state.session_id == session_id do
      {:noreply, state}
    else
      unsubscribe_session(state.session_id)
      subscribe_session(session_id)
      {:noreply, %{state | session_id: session_id}}
    end
  end

  @impl true
  def handle_cast({:bind_session, _invalid_session_id}, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_response, text}, state) do
    Pincer.Channels.WhatsApp.send_message(state.chat_id, text)
    maybe_advance_project_flow(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_error, text}, state) do
    Pincer.Channels.WhatsApp.send_message(state.chat_id, "Agent error: #{text}")
    maybe_recover_project_flow(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_status, text}, state) do
    Pincer.Channels.WhatsApp.send_message(state.chat_id, text)
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_partial, _token}, state), do: {:noreply, state}

  @impl true
  def handle_info({:agent_thinking, _text}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp default_session_id(chat_id), do: "whatsapp_#{chat_id}"

  defp normalize_session_id(_chat_id, session_id)
       when is_binary(session_id) and session_id != "",
       do: session_id

  defp normalize_session_id(chat_id, _), do: default_session_id(chat_id)

  defp subscribe_session(session_id), do: Pincer.PubSub.subscribe("session:#{session_id}")
  defp unsubscribe_session(session_id), do: Pincer.PubSub.unsubscribe("session:#{session_id}")

  defp maybe_advance_project_flow(state) do
    case ProjectRouter.on_agent_response(state.session_id) do
      {:next, progress} ->
        Pincer.Channels.WhatsApp.send_message(
          state.chat_id,
          "Project Runner: #{progress.status_message}"
        )

        _ = Server.process_input(state.session_id, progress.prompt)
        :ok

      {:completed, progress} ->
        Pincer.Channels.WhatsApp.send_message(
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
        Pincer.Channels.WhatsApp.send_message(
          state.chat_id,
          "Project Runner: #{progress.status_message}"
        )

        _ = Server.process_input(state.session_id, progress.prompt)
        :ok

      {:paused, progress} ->
        Pincer.Channels.WhatsApp.send_message(
          state.chat_id,
          "Project Runner: #{progress.status_message}"
        )

        :ok

      :noop ->
        :ok
    end
  end
end
