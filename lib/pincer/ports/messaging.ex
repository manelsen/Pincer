defmodule Pincer.Ports.Messaging do
  @moduledoc """
  Compatibility entry point for outbound delivery through `PincerPorts.Messaging`.

  New callers and adapters should use `PincerPorts.Messaging` directly.
  """

  @type channel :: PincerPorts.Messaging.channel()
  @type attachment :: PincerPorts.Messaging.attachment()
  @type result :: PincerPorts.Messaging.result()

  @callback deliver(String.t(), String.t()) :: :ok | {:error, term()}
  @callback send_message(channel(), String.t(), String.t(), keyword()) :: result()
  @callback send_file(channel(), String.t(), attachment(), String.t()) :: :ok | result()

  @doc "Dispatches a message to the session's channel."
  @spec deliver(String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate deliver(session_id, message), to: PincerPorts.Messaging

  @doc "Sends text to a recipient on the selected channel."
  @spec send_message(channel(), String.t(), String.t(), keyword()) :: result()
  defdelegate send_message(channel, recipient, text, opts \\ []), to: PincerPorts.Messaging

  @doc "Sends a workspace-checked file to a recipient on the selected channel."
  @spec send_file(channel(), String.t(), attachment(), String.t()) :: :ok | result()
  defdelegate send_file(channel, recipient, file, caption), to: PincerPorts.Messaging

  @doc "Sends text as a reply to a channel message."
  @spec reply_to(channel(), String.t(), String.t(), String.t()) :: result()
  defdelegate reply_to(channel, recipient, message_id, text), to: PincerPorts.Messaging
end
