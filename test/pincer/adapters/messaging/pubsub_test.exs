defmodule Pincer.Adapters.Messaging.PubSubTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Messaging.PubSub

  defmodule TestPubSub do
    def broadcast(topic, message) do
      send(self(), {:broadcast, topic, message})
      :ok
    end
  end

  defmodule TelegramStub do
    def send_message(recipient, text, opts) do
      send(self(), {:telegram_message, recipient, text, opts})
      {:ok, 101}
    end

    def send_document(recipient, path, opts) do
      send(self(), {:telegram_document, recipient, path, opts})
      :ok
    end
  end

  defmodule DiscordStub do
    def send_message(recipient, text, opts) do
      send(self(), {:discord_message, recipient, text, opts})
      {:ok, 202}
    end
  end

  test "deliver broadcasts to system:delivery via configured PubSub port" do
    previous = Application.fetch_env(:pincer, :pubsub_adapter)
    Application.put_env(:pincer, :pubsub_adapter, TestPubSub)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:pincer, :pubsub_adapter, adapter)
        :error -> Application.delete_env(:pincer, :pubsub_adapter)
      end
    end)

    assert :ok = PubSub.deliver("session-1", "hello")
    assert_received {:broadcast, "system:delivery", {:deliver_message, "session-1", "hello"}}
  end

  test "returns a transport error for an unknown or unconfigured channel" do
    assert {:error, {:unsupported_channel, :unknown}} =
             PubSub.send_message(:unknown, "recipient", "message", [])
  end

  test "routes send_message and send_file through configured channel_actions_adapters" do
    previous = Application.fetch_env(:pincer, :channel_actions_adapters)

    Application.put_env(:pincer, :channel_actions_adapters, %{
      telegram: TelegramStub,
      discord: DiscordStub
    })

    on_exit(fn ->
      case previous do
        {:ok, adapters} -> Application.put_env(:pincer, :channel_actions_adapters, adapters)
        :error -> Application.delete_env(:pincer, :channel_actions_adapters)
      end
    end)

    assert {:ok, 101} = PubSub.send_message(:telegram, "123", "hi", reply_to_message_id: "9")
    assert_received {:telegram_message, "123", "hi", [reply_to_message_id: "9"]}

    file = %{name: "note.txt", path: "/tmp/note.txt", body: "hello"}
    assert :ok = PubSub.send_file(:telegram, "123", file, "cap")
    assert_received {:telegram_document, "123", "/tmp/note.txt", [caption: "cap"]}

    assert {:ok, 202} = PubSub.send_file(:discord, "456", file, "cap")
    assert_received {:discord_message, "456", "cap", [files: [^file]]}
  end

  test "reports that WhatsApp does not support file uploads through this adapter" do
    file = %{name: "document.txt", path: "/unused/document.txt", body: "document"}

    assert {:error, "File sending is not supported on WhatsApp (file: document.txt)."} =
             PubSub.send_file(:whatsapp, "recipient", file, "")
  end
end
