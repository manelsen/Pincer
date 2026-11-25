defmodule Pincer.Core.Streaming.Adapter do
  @moduledoc """
  Implements `PincerPorts.Streaming` on top of the Core presentation policies.

  The single place that maps the port's flat surface to the individual policy
  modules, so channel sessions depend on the port alone.
  """

  @behaviour PincerPorts.Streaming

  alias Pincer.Core.SubAgentProgress
  alias Pincer.Core.StatusDelivery
  alias Pincer.Core.StatusMessagePolicy
  alias Pincer.Core.StreamDelivery
  alias Pincer.Core.StreamingPolicy

  @impl true
  def stream_initial_state, do: StreamingPolicy.initial_state()

  @impl true
  def stream_extract(assigns), do: StreamingPolicy.extract(assigns)

  @impl true
  def stream_assign(assigns, state), do: StreamingPolicy.assign(assigns, state)

  @impl true
  def stream_on_partial(state, token, now_ms, opts),
    do: StreamingPolicy.on_partial(state, token, now_ms, opts)

  @impl true
  def stream_mark_rendered(state, message_id, now_ms),
    do: StreamingPolicy.mark_rendered(state, message_id, now_ms)

  @impl true
  def stream_on_final(state, text), do: StreamingPolicy.on_final(state, text)

  @impl true
  def handle_partial(state, token, now_ms, transport, opts),
    do: StreamDelivery.handle_partial(state, token, now_ms, transport, opts)

  @impl true
  def handle_final(state, text, transport),
    do: StreamDelivery.handle_final(state, text, transport)

  @impl true
  def status_initial_state, do: StatusMessagePolicy.initial_state()

  @impl true
  def status_next_action(state, text), do: StatusMessagePolicy.next_action(state, text)

  @impl true
  def status_mark_sent(state, message_id, text),
    do: StatusMessagePolicy.mark_sent(state, message_id, text)

  @impl true
  def status_mark_edited(state, text), do: StatusMessagePolicy.mark_edited(state, text)

  @impl true
  def deliver_status(state, text, transport), do: StatusDelivery.deliver(state, text, transport)

  @impl true
  def progress_apply_event(tracker, event), do: SubAgentProgress.apply_event(tracker, event)

  @impl true
  def progress_render_dashboard(tracker), do: SubAgentProgress.render_dashboard(tracker)

  @impl true
  def progress_notifications(messages, tracker),
    do: SubAgentProgress.notifications(messages, tracker)
end
