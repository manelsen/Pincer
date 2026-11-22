defmodule Pincer.Ports.ChannelPolicy do
  @moduledoc """
  Port for the access and approval rules a channel must apply.

  Direct-message gating, pairing and tool-approval prompts are agent-runtime
  decisions, but every transport has to ask for them. The port keeps those
  calls out of the packages so a channel never imports `Pincer.Core.Policy`,
  `Pairing` or the interaction-policy modules directly.

  ## Example

      case Pincer.Ports.ChannelPolicy.allow?(:dm_access, %{channel: :telegram, sender_id: id}) do
        {:allow, _} -> handle(message)
        {:deny, %{user_message: text}} -> send_message(chat_id, text)
      end
  """

  @type channel :: atom()
  @type sender_id :: term()
  @type decision :: {:allow, map()} | {:deny, map()}

  @callback allow?(atom(), map()) :: decision() | {:error, term()}
  @callback classify(atom(), map()) :: term()
  @callback approve_code(channel(), sender_id(), String.t(), keyword()) :: term()
  @callback bound_agent_id(channel(), sender_id()) :: term()
  @callback provider_selector_id(channel(), String.t()) :: String.t()
  @callback model_selector_id(channel(), String.t(), String.t()) :: String.t()
  @callback back_to_providers_id(channel()) :: String.t()
  @callback menu_id(channel()) :: String.t()
  @callback approval_button_spec() :: term()
  @callback parse(channel(), String.t()) :: term()
  @callback error_message(channel(), String.t()) :: String.t()
  @callback approval_message(channel(), String.t()) :: String.t()
  @callback status_kind(String.t()) :: term()
  @callback emit_error(term(), map()) :: term()

  @doc false
  def adapter do
    Application.get_env(:pincer, :channel_policy_adapter, Pincer.Core.ChannelPolicy.Adapter)
  end

  def allow?(kind, attrs), do: adapter().allow?(kind, attrs)
  def classify(kind, attrs), do: adapter().classify(kind, attrs)

  def approve_code(channel, sender_id, code, opts \\ []),
    do: adapter().approve_code(channel, sender_id, code, opts)

  def bound_agent_id(channel, sender_id), do: adapter().bound_agent_id(channel, sender_id)
  def provider_selector_id(channel, id), do: adapter().provider_selector_id(channel, id)

  def model_selector_id(channel, provider_id, model),
    do: adapter().model_selector_id(channel, provider_id, model)

  def back_to_providers_id(channel), do: adapter().back_to_providers_id(channel)
  def menu_id(channel), do: adapter().menu_id(channel)
  def approval_button_spec(), do: adapter().approval_button_spec()
  def parse(channel, payload), do: adapter().parse(channel, payload)
  def error_message(channel, text), do: adapter().error_message(channel, text)
  def approval_message(channel, command), do: adapter().approval_message(channel, command)
  def status_kind(text), do: adapter().status_kind(text)
  def emit_error(reason, meta \\ %{}), do: adapter().emit_error(reason, meta)
end
