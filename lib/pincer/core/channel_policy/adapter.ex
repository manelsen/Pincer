defmodule Pincer.Core.ChannelPolicy.Adapter do
  @moduledoc """
  Implements `Pincer.Ports.ChannelPolicy` on top of the Core policy modules.

  The only place that knows which Core module owns each rule, so channel
  packages can depend on the port alone.
  """

  @behaviour Pincer.Ports.ChannelPolicy

  alias Pincer.Core.{ChannelEventPolicy, ChannelInteractionPolicy, Pairing, Policy}

  @impl true
  def allow?(kind, attrs), do: Policy.allow?(kind, attrs)

  @impl true
  def classify(kind, attrs), do: Policy.classify(kind, attrs)

  @impl true
  def approve_code(channel, sender_id, code, opts),
    do: Pairing.approve_code(channel, sender_id, code, opts)

  @impl true
  def bound_agent_id(channel, sender_id), do: Pairing.bound_agent_id(channel, sender_id)

  @impl true
  def provider_selector_id(channel, id),
    do: ChannelInteractionPolicy.provider_selector_id(channel, id)

  @impl true
  def model_selector_id(channel, provider_id, model),
    do: ChannelInteractionPolicy.model_selector_id(channel, provider_id, model)

  @impl true
  def back_to_providers_id(channel), do: ChannelInteractionPolicy.back_to_providers_id(channel)

  @impl true
  def menu_id(channel), do: ChannelInteractionPolicy.menu_id(channel)

  @impl true
  def approval_button_spec, do: ChannelInteractionPolicy.approval_button_spec()

  @impl true
  def parse(channel, payload), do: ChannelInteractionPolicy.parse(channel, payload)

  @impl true
  def error_message(channel, text), do: ChannelEventPolicy.error_message(channel, text)

  @impl true
  def approval_message(channel, command),
    do: ChannelEventPolicy.approval_message(channel, command)

  @impl true
  def status_kind(text), do: ChannelEventPolicy.status_kind(text)
end
