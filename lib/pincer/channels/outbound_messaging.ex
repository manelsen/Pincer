defmodule Pincer.Channels.OutboundMessaging do
  @moduledoc "Routes outbound messages to the configured channel implementations."

  @behaviour PincerPorts.Messaging

  @channels %{
    telegram: Pincer.Channels.Telegram,
    discord: Pincer.Channels.Discord,
    whatsapp: Pincer.Channels.WhatsApp
  }

  @impl true
  def deliver(session_id, text) do
    PincerPorts.PubSub.broadcast("system:delivery", {:deliver_message, session_id, text})
  end

  @impl true
  def send_message(channel, recipient, text, opts) do
    with {:ok, adapter} <- channel_adapter(channel) do
      adapter.send_message(recipient, text, opts)
    end
  end

  @impl true
  def send_file(:telegram, recipient, %{path: path}, caption) do
    {:ok, adapter} = channel_adapter(:telegram)
    adapter.send_document(recipient, path, caption: caption)
  end

  def send_file(:discord, recipient, file, caption) do
    send_message(:discord, recipient, caption, files: [file])
  end

  def send_file(:whatsapp, _recipient, %{name: name}, _caption) do
    {:error, "File sending is not supported on WhatsApp (file: #{name})."}
  end

  def send_file(channel, _recipient, _file, _caption) do
    {:error, {:unsupported_channel, channel}}
  end

  defp channel_adapter(channel) do
    case Map.fetch(@channels, channel) do
      {:ok, default} ->
        overrides = Application.get_env(:pincer, :channel_actions_adapters, %{})
        {:ok, Map.get(overrides, channel, default)}

      :error ->
        {:error, {:unsupported_channel, channel}}
    end
  end
end
