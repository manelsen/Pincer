defmodule Pincer.Ports.Streaming do
  @moduledoc """
  Port for the streaming and status-presentation policies a channel session needs.

  Token-by-token previews, status lines, final delivery and sub-agent progress
  are rendered differently per transport but decided uniformly by the runtime.
  The decision functions live in Core, so a channel asks this port for them
  instead of importing them directly.

  State is opaque: each policy returns the next state, and the caller keeps it.
  """

  @type state :: map()
  @type transport :: atom()
  @type tracker :: map()

  @callback stream_initial_state() :: state()
  @callback stream_extract(map()) :: state()
  @callback stream_assign(map(), state()) :: map()
  @callback stream_on_partial(state(), String.t(), integer(), keyword()) :: state()
  @callback stream_mark_rendered(state(), term(), integer()) :: state()
  @callback stream_on_final(state(), String.t()) :: term()
  @callback handle_partial(state(), String.t(), integer(), transport(), keyword()) :: term()
  @callback handle_final(state(), String.t(), transport()) :: term()
  @callback status_initial_state() :: state()
  @callback status_next_action(state(), String.t()) :: term()
  @callback status_mark_sent(state(), integer(), String.t()) :: state()
  @callback status_mark_edited(state(), String.t()) :: state()
  @callback deliver_status(state(), String.t(), transport()) :: term()
  @callback progress_apply_event(tracker(), map()) :: tracker()
  @callback progress_render_dashboard(tracker()) :: term()
  @callback progress_notifications([map()], tracker()) :: term()

  @doc false
  def adapter do
    Application.get_env(:pincer, :streaming_adapter, Pincer.Core.Streaming.Adapter)
  end

  def stream_initial_state, do: adapter().stream_initial_state()
  def stream_extract(assigns), do: adapter().stream_extract(assigns)
  def stream_assign(assigns, state), do: adapter().stream_assign(assigns, state)

  def stream_on_partial(state, token, now_ms, opts \\ []),
    do: adapter().stream_on_partial(state, token, now_ms, opts)

  def stream_mark_rendered(state, message_id, now_ms),
    do: adapter().stream_mark_rendered(state, message_id, now_ms)

  def stream_on_final(state, text), do: adapter().stream_on_final(state, text)

  def handle_partial(state, token, now_ms, transport, opts \\ []),
    do: adapter().handle_partial(state, token, now_ms, transport, opts)

  def handle_final(state, text, transport), do: adapter().handle_final(state, text, transport)

  def status_initial_state, do: adapter().status_initial_state()
  def status_next_action(state, text), do: adapter().status_next_action(state, text)

  def status_mark_sent(state, message_id, text),
    do: adapter().status_mark_sent(state, message_id, text)

  def status_mark_edited(state, text), do: adapter().status_mark_edited(state, text)
  def deliver_status(state, text, transport), do: adapter().deliver_status(state, text, transport)

  def progress_apply_event(tracker, event), do: adapter().progress_apply_event(tracker, event)
  def progress_render_dashboard(tracker), do: adapter().progress_render_dashboard(tracker)

  def progress_notifications(messages, tracker \\ %{}),
    do: adapter().progress_notifications(messages, tracker)
end
