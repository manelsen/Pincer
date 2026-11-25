defmodule Pincer.Adapters.Messaging.PubSub do
  @moduledoc """
  Messaging port adapter that delivers session updates over PubSub and routes
  explicit channel actions to runtime-configured channel adapters.
  """

  @behaviour PincerPorts.Messaging

  @impl true
  @spec deliver(String.t(), String.t()) :: :ok
  def deliver(session_id, text) do
    PincerPorts.PubSub.broadcast("system:delivery", {:deliver_message, session_id, text})
  end

  @impl true
  @spec send_message(
          PincerPorts.Messaging.channel(),
          String.t(),
          String.t(),
          keyword()
        ) :: PincerPorts.Messaging.result()
  def send_message(channel, recipient, text, opts) do
    with {:ok, adapter} <- channel_adapter(channel) do
      adapter.send_message(recipient, text, opts)
    end
  end

  @impl true
  @spec send_file(
          PincerPorts.Messaging.channel(),
          String.t(),
          PincerPorts.Messaging.attachment(),
          String.t()
        ) :: :ok | PincerPorts.Messaging.result()
  def send_file(:telegram, recipient, %{path: path}, caption) do
    with {:ok, adapter} <- channel_adapter(:telegram) do
      adapter.send_document(recipient, path, caption: caption)
    end
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
    adapters = Application.get_env(:pincer, :channel_actions_adapters, %{})

    case Map.fetch(adapters, channel) do
      {:ok, adapter} when is_atom(adapter) and not is_nil(adapter) ->
        {:ok, adapter}

      _ ->
        {:error, {:unsupported_channel, channel}}
    end
  end
end
