defmodule PincerPorts.Messaging do
  @moduledoc """
  Outbound text, file, and reply delivery through the host's messaging adapter.
  """

  @type channel :: atom()
  @type attachment :: %{name: String.t(), body: binary(), path: String.t()}
  @type result :: {:ok, term()} | {:error, term()}

  @callback deliver(String.t(), String.t()) :: :ok | {:error, term()}
  @callback send_message(channel(), String.t(), String.t(), keyword()) :: result()
  @callback send_file(channel(), String.t(), attachment(), String.t()) :: :ok | result()

  @doc "Publishes text to a session's channel."
  @spec deliver(String.t(), String.t()) :: :ok | {:error, term()}
  def deliver(session_id, text), do: adapter().deliver(session_id, text)

  @doc "Sends text to a recipient on the selected channel."
  @spec send_message(channel(), String.t(), String.t(), keyword()) :: result()
  def send_message(channel, recipient, text, opts \\ []) do
    adapter().send_message(channel, recipient, text, opts)
  end

  @doc "Sends a workspace-checked file to a recipient on the selected channel."
  @spec send_file(channel(), String.t(), attachment(), String.t()) :: :ok | result()
  def send_file(channel, recipient, file, caption) do
    adapter().send_file(channel, recipient, file, caption)
  end

  @doc "Sends text as a reply to a channel message."
  @spec reply_to(channel(), String.t(), String.t(), String.t()) :: result()
  def reply_to(channel, recipient, message_id, text) do
    send_message(channel, recipient, text, reply_to_message_id: message_id)
  end

  defp adapter, do: Application.fetch_env!(:pincer, :messaging_adapter)
end
