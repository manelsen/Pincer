defmodule Pincer.Channels.Discord.Session do
  @compile {:no_warn_undefined, [
    Pincer.Core.ChannelEventPolicy,
    Pincer.Core.ChannelInteractionPolicy,
    Pincer.Core.ProjectFlowDelivery,
    Pincer.Core.Session.Registry,
    Pincer.Core.StatusDelivery,
    Pincer.Core.StatusMessagePolicy,
    Pincer.Core.StreamDelivery,
    Pincer.Core.StreamingPolicy,
    Pincer.Core.SubAgentProgress,
    Pincer.Infra.PubSub,
    Pincer.Ports.LLM
  ]}
  @moduledoc """
  Driven Adapter for Discord.
  One process per active Discord channel that listens to PubSub and sends messages via Nostrum.
  """
  use Pincer.Ports.Channel
  alias Pincer.Core.ChannelEventPolicy
  alias Pincer.Core.ChannelInteractionPolicy
  alias Pincer.Core.ProjectFlowDelivery
  alias Pincer.Core.StatusDelivery
  alias Pincer.Core.StatusMessagePolicy
  alias Pincer.Core.StreamDelivery
  alias Pincer.Core.StreamingPolicy
  alias Pincer.Core.SubAgentProgress

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
    super(args)
    subscribe_session(session_id)
    Logger.info("[DISCORD SESSION] Worker started for channel: #{channel_id}")
    {:ok, state(channel_id, session_id)}
  end

  @impl true
  def init(channel_id) do
    session_id = default_session_id(channel_id)
    super(channel_id)
    subscribe_session(session_id)
    Logger.info("[DISCORD SESSION] Worker started for channel: #{channel_id}")
    {:ok, state(channel_id, session_id)}
  end

  @impl Pincer.Ports.Channel
  def handles_session?(id), do: String.starts_with?(id, "discord_")

  @impl Pincer.Ports.Channel
  def resolve_recipient(id) do
    case String.split(id, "_", parts: 2) do
      ["discord", channel_id] -> channel_id
      _ -> id
    end
  end

  @impl Pincer.Ports.Channel
  def send_message(channel_id, text) do
    Pincer.Channels.Discord.send_message(channel_id, text)
  end

  # --- Session bind ---

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

  # --- Session PubSub callbacks ---

  @impl true
  def on_agent_partial(token, state) do
    StreamDelivery.handle_partial(
      state,
      token,
      System.system_time(:millisecond),
      stream_transport(state)
    )
  end

  @impl true
  def on_agent_response(text, _usage, state) do
    state = StreamDelivery.handle_final(state, text, stream_transport(state))
    maybe_advance_project_flow(state)
    state
  end

  @impl true
  def on_agent_error(text, state) do
    Pincer.Channels.Discord.send_message(
      "#{state.channel_id}",
      ChannelEventPolicy.error_message(:discord, text)
    )

    maybe_recover_project_flow(state)
    state
  end

  @impl true
  def on_agent_status(text, state) do
    if ChannelEventPolicy.status_kind(text) == :subagent do
      deliver_subagent_status(state, text)
    else
      Pincer.Channels.Discord.send_message("#{state.channel_id}", text)
      state
    end
  end

  @impl true
  def on_agent_thinking(text, state) do
    Logger.debug("[DISCORD SESSION] Agent thinking: #{text}")
    state
  end

  @impl true
  def on_subagent_progress(event, state) do
    tracker = SubAgentProgress.apply_event(state.subagent_progress_tracker, event)
    dashboard = SubAgentProgress.render_dashboard(tracker)

    %{state | subagent_progress_tracker: tracker}
    |> deliver_subagent_dashboard(dashboard)
  end

  @impl true
  def on_approval_ui(_call_id, command, state) do
    text = ChannelEventPolicy.approval_message(:discord, command)
    components = build_approval_components()
    Pincer.Channels.Discord.send_message("#{state.channel_id}", text, components: components)
    state
  end

  # --- Private helpers ---

  defp stream_transport(state) do
    channel_id = "#{state.channel_id}"

    [
      send: fn text ->
        Pincer.Channels.Discord.send_message(channel_id, text)
      end,
      edit: fn message_id, text ->
        Pincer.Channels.Discord.update_message(channel_id, message_id, text)
      end
    ]
  end

  defp deliver_subagent_dashboard(state, nil), do: state

  defp deliver_subagent_dashboard(state, text) do
    channel_id = "#{state.channel_id}"

    StatusDelivery.deliver(
      state,
      text,
      send: fn content -> Pincer.Channels.Discord.send_message(channel_id, content) end,
      edit: fn message_id, content ->
        Pincer.Channels.Discord.update_message(channel_id, message_id, content)
      end
    )
  end

  defp build_approval_components do
    buttons =
      ChannelInteractionPolicy.approval_button_spec()
      |> Enum.with_index()
      |> Enum.map(fn {{label, payload}, idx} ->
        style = if idx == 0, do: 3, else: 4
        %{type: 2, style: style, label: label, custom_id: payload}
      end)

    [%{type: 1, components: buttons}]
  end

  defp deliver_subagent_status(state, text) do
    channel_id = "#{state.channel_id}"

    StatusDelivery.deliver(
      state,
      text,
      send: fn content -> Pincer.Channels.Discord.send_message(channel_id, content) end,
      edit: fn message_id, content ->
        Pincer.Channels.Discord.update_message(channel_id, message_id, content)
      end
    )
  end

  defp maybe_advance_project_flow(state) do
    ProjectFlowDelivery.on_response(
      state.session_id,
      send_message: fn text ->
        Pincer.Channels.Discord.send_message("#{state.channel_id}", text)
      end
    )
  end

  defp maybe_recover_project_flow(state) do
    ProjectFlowDelivery.on_error(
      state.session_id,
      send_message: fn text ->
        Pincer.Channels.Discord.send_message("#{state.channel_id}", text)
      end
    )
  end

  defp default_session_id(channel_id), do: "discord_#{channel_id}"

  defp normalize_session_id(_channel_id, session_id)
       when is_binary(session_id) and session_id != "",
       do: session_id

  defp normalize_session_id(channel_id, _), do: default_session_id(channel_id)

  defp subscribe_session(session_id), do: Pincer.Infra.PubSub.subscribe("session:#{session_id}")

  defp unsubscribe_session(session_id),
    do: Pincer.Infra.PubSub.unsubscribe("session:#{session_id}")

  defp state(channel_id, session_id) do
    Map.merge(
      Map.merge(
        %{
          channel_id: channel_id,
          session_id: session_id,
          subagent_progress_tracker: %{}
        },
        StatusMessagePolicy.initial_state()
      ),
      StreamingPolicy.initial_state()
    )
  end
end
