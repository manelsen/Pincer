defmodule Pincer.Channels.Telegram.Session do
  @moduledoc """
  Driven Adapter for Telegram.
  One process per active chat that listens to PubSub and sends to the Telegram API.
  """
  use PincerPorts.Channel
  alias Pincer.Channels.Shared.SessionBridge
  alias Pincer.Channels.Telegram.ResponseEnvelope

  @preview_suppress_threshold 500

  @impl PincerPorts.Channel
  def start_link(%{chat_id: chat_id} = args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(chat_id))
  end

  def start_link(chat_id) do
    GenServer.start_link(__MODULE__, chat_id, name: via_tuple(chat_id))
  end

  defp via_tuple(chat_id), do: SessionBridge.via_tuple(:telegram, chat_id)

  def ensure_started(chat_id, session_id \\ nil)

  def ensure_started(chat_id, session_id) do
    SessionBridge.ensure_started({:telegram, chat_id},
      session_id: session_id,
      start_worker: &Pincer.Channels.Telegram.SessionSupervisor.start_session/2,
      already_started: :error
    )
  end

  @doc """
  Resolves the `PincerPorts.Session.Context` for a Telegram chat.
  """
  @spec context_for_chat(String.t() | integer(), String.t() | nil) ::
          PincerPorts.Session.Context.t()
  def context_for_chat(chat_id, chat_type) do
    channel_config = Application.get_env(:pincer, :telegram_channel_config, %{})

    PincerPorts.Session.resolve(
      :telegram,
      %{chat_id: chat_id, chat_type: chat_type},
      channel_config
    )
  end

  @doc """
  Ensures the core session process for `context` is running.
  """
  @spec ensure_core_started(PincerPorts.Session.Context.t()) :: :ok | {:ok, pid()} | {:error, term()}
  def ensure_core_started(%PincerPorts.Session.Context{} = context) do
    SessionBridge.ensure_started(context,
      on_start: fn sid ->
        Logger.info(
          "[TELEGRAM] Creating new session: #{sid} (root_agent=#{context.root_agent_id})"
        )
      end
    )
  end

  @impl true
  def init(%{chat_id: chat_id, session_id: session_id} = args)
      when is_binary(session_id) and session_id != "" do
    super(args)
    SessionBridge.subscribe(session_id)
    {:ok, state(chat_id, session_id)}
  end

  @impl true
  def init(chat_id) do
    session_id = SessionBridge.default_session_id(:telegram, chat_id)
    super(chat_id)
    SessionBridge.subscribe(session_id)
    {:ok, state(chat_id, session_id)}
  end

  @impl PincerPorts.Channel
  def handles_session?(id), do: SessionBridge.handles_session?(:telegram, id)

  @impl PincerPorts.Channel
  def resolve_recipient(id), do: SessionBridge.resolve_recipient(:telegram, id)

  @impl PincerPorts.Channel
  def send_message(chat_id, text) do
    Pincer.Channels.Telegram.send_message(chat_id, text)
  end

  # --- Session bind ---

  @impl true
  def handle_cast({:bind_session, session_id}, state) do
    SessionBridge.bind_session(state, session_id,
      on_rebind: fn s, sid -> state(s.chat_id, sid) end
    )
  end

  # --- Session PubSub callbacks ---

  @impl true
  def on_agent_partial(token, state) do
    session_status = session_status(state.session_id)

    PincerPorts.Streaming.handle_partial(
      state,
      token,
      System.system_time(:millisecond),
      stream_transport(state, session_status, skip_formatting: true),
      suppress_preview?: &suppress_preview?/2
    )
  end

  @impl true
  def on_agent_response(text, usage, state) do
    session_status = session_status(state.session_id)

    text_with_usage =
      ResponseEnvelope.build(
        text,
        usage,
        Map.get(session_status, :usage_display)
      )

    state = reset_tool_state(state)

    if text_with_usage != "" do
      state =
        PincerPorts.Streaming.handle_final(
          state,
          text_with_usage,
          stream_transport(state, session_status, skip_formatting: false)
        )

      maybe_advance_project_flow(state)
      state
    else
      state
    end
  end

  @impl true
  def on_agent_error(text, state) do
    Pincer.Channels.Telegram.send_message(
      state.chat_id,
      PincerPorts.ChannelPolicy.error_message(:telegram, text)
    )

    maybe_recover_project_flow(state)
    state
  end

  @impl true
  def on_agent_status(text, state) do
    if PincerPorts.ChannelPolicy.status_kind(text) == :subagent,
      do: state,
      else: deliver_status(state, text)
  end

  @impl true
  def on_agent_thinking(_text, state) do
    Telegex.send_chat_action(state.chat_id, "typing")
    state
  end

  @impl true
  def on_subagent_progress(event, state) do
    tracker = PincerPorts.Streaming.progress_apply_event(state.subagent_progress_tracker, event)
    dashboard = PincerPorts.Streaming.progress_render_dashboard(tracker)

    %{state | subagent_progress_tracker: tracker}
    |> deliver_subagent_dashboard(dashboard)
  end

  @impl true
  def on_agent_file(path, opts, state) do
    caption_opts = if is_binary(opts[:caption]), do: [caption: opts[:caption]], else: []

    case Pincer.Channels.Telegram.send_document(state.chat_id, path, caption_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Telegram] Failed to send document: #{inspect(reason)}")

        Pincer.Channels.Telegram.send_message(
          state.chat_id,
          "⚠️ Failed to send file: #{Path.basename(path)}"
        )
    end

    state
  end

  @impl true
  def on_approval_ui(_call_id, command, state) do
    text = PincerPorts.ChannelPolicy.approval_message(:telegram, command)

    buttons =
      PincerPorts.ChannelPolicy.approval_button_spec()
      |> Enum.map(fn {label, payload} ->
        %Telegex.Type.InlineKeyboardButton{text: label, callback_data: payload}
      end)

    Pincer.Channels.Telegram.send_message(
      state.chat_id,
      text,
      reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: [buttons]}
    )

    state
  end

  # --- Private helpers ---

  defp session_status(session_id) do
    try do
      case PincerPorts.Session.get_status(session_id) do
        {:ok, status} when is_map(status) -> status
        _ -> %{}
      end
    catch
      :exit, _reason -> %{}
    end
  rescue
    _ -> %{}
  end

  defp stream_transport(state, session_status, extra_opts) do
    opts =
      session_status
      |> ResponseEnvelope.delivery_options()
      |> Keyword.merge(extra_opts)

    [
      send: fn text ->
        Pincer.Channels.Telegram.send_message(state.chat_id, text, opts)
      end,
      edit: fn message_id, text ->
        Pincer.Channels.Telegram.update_message(state.chat_id, message_id, text, opts)
      end
    ]
  end

  @tool_prefix "🛠️ Usando ferramentas:"
  @orchestration_prefix "⚡ **Orquestração Paralela**"
  @tool_window_size 8

  defp deliver_status(state, @tool_prefix <> _ = text) do
    new_names = extract_tool_names(text)
    updated_calls = append_tool_calls(state.tool_calls, new_names, @tool_window_size)
    rendered = render_tool_window(state.orchestration_note, updated_calls)

    %{state | tool_calls: updated_calls}
    |> PincerPorts.Streaming.deliver_status(
      rendered,
      send: fn content -> Pincer.Channels.Telegram.send_message(state.chat_id, content) end,
      edit: fn message_id, content ->
        Pincer.Channels.Telegram.update_message(state.chat_id, message_id, content)
      end
    )
  end

  defp deliver_status(state, @orchestration_prefix <> _ = text) do
    note = String.replace(text, ~r/\*\*/u, "") |> String.trim()
    updated = %{state | orchestration_note: note}
    rendered = render_tool_window(note, updated.tool_calls)

    updated
    |> PincerPorts.Streaming.deliver_status(
      rendered,
      send: fn content -> Pincer.Channels.Telegram.send_message(state.chat_id, content) end,
      edit: fn message_id, content ->
        Pincer.Channels.Telegram.update_message(state.chat_id, message_id, content)
      end
    )
  end

  defp deliver_status(state, text) do
    Pincer.Channels.Telegram.send_message(state.chat_id, text)
    state
  end

  defp extract_tool_names(@tool_prefix <> rest) do
    rest
    |> String.trim()
    |> String.split(~r/[\n,]\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp append_tool_calls(calls, new_names, window_size) do
    (calls ++ new_names) |> Enum.take(-window_size)
  end

  defp render_tool_window(_note, []), do: ""

  defp render_tool_window(note, calls) do
    tool_lines =
      calls
      |> Enum.chunk_by(& &1)
      |> Enum.map(fn
        [name] -> name
        [name | _] = group -> "#{name} ×#{length(group)}"
      end)
      |> Enum.map_join("\n→ ", & &1)

    body =
      if note do
        "#{note}\n─────────────────────\n⚙️ #{tool_lines}"
      else
        "⚙️ #{tool_lines}"
      end

    "Aguarde…\n<blockquote>#{body}</blockquote>"
  end

  defp reset_tool_state(state) do
    state
    |> Map.put(:tool_calls, [])
    |> Map.put(:orchestration_note, nil)
    |> Map.merge(PincerPorts.Streaming.status_initial_state())
  end

  defp deliver_subagent_dashboard(state, nil), do: state

  defp deliver_subagent_dashboard(state, text) do
    PincerPorts.Streaming.deliver_status(
      state,
      text,
      send: fn content -> Pincer.Channels.Telegram.send_message(state.chat_id, content) end,
      edit: fn message_id, content ->
        Pincer.Channels.Telegram.update_message(state.chat_id, message_id, content)
      end
    )
  end

  defp maybe_advance_project_flow(state) do
    Pincer.Channels.Shared.ProjectBridge.on_agent_response(state.session_id, fn text ->
      Pincer.Channels.Telegram.send_message(state.chat_id, text)
    end)
  end

  defp maybe_recover_project_flow(state) do
    Pincer.Channels.Shared.ProjectBridge.on_agent_error(state.session_id, fn text ->
      Pincer.Channels.Telegram.send_message(state.chat_id, text)
    end)
  end

  defp state(chat_id, session_id) do
    SessionBridge.initial_state(
      %{
        chat_id: chat_id,
        session_id: session_id,
        preview_suppressed: false,
        subagent_progress_tracker: %{},
        tool_calls: [],
        orchestration_note: nil
      },
      streaming: true
    )
  end

  defp suppress_preview?(%{preview_suppressed: true}, _token), do: true

  defp suppress_preview?(state, token) do
    stream_state = PincerPorts.Streaming.stream_extract(state)

    is_nil(stream_state.message_id) and stream_state.buffer == "" and synthetic_partial?(token)
  end

  defp synthetic_partial?(token) do
    text = to_string(token)

    String.length(text) > @preview_suppress_threshold or
      Regex.match?(~r/<(thinking|thought)>.*?<\/(thinking|thought)>/is, text)
  end
end
