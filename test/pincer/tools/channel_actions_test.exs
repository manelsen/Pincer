defmodule Pincer.Adapters.Tools.ChannelActionsTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.ChannelActions

  defmodule ChannelActionsTelegramStub do
    def send_message(recipient, content, _opts \\ []) do
      send(test_pid(), {:telegram_send, recipient, content})
      {:ok, 101}
    end

    defp test_pid do
      Application.fetch_env!(:pincer, :channel_actions_test_pid)
    end
  end

  defmodule ChannelActionsDiscordStub do
    def send_message(recipient, content, _opts \\ []) do
      send(test_pid(), {:discord_send, recipient, content})
      {:ok, 202}
    end

    defp test_pid do
      Application.fetch_env!(:pincer, :channel_actions_test_pid)
    end
  end

  defmodule ChannelActionsWhatsAppStub do
    def send_message(recipient, content, _opts \\ []) do
      send(test_pid(), {:whatsapp_send, recipient, content})
      {:ok, 303}
    end

    defp test_pid do
      Application.fetch_env!(:pincer, :channel_actions_test_pid)
    end
  end

  defmodule SessionServerStub do
    def get_status("telegram_123") do
      {:ok, %{session_id: "telegram_123", principal_ref: "telegram:user:123"}}
    end

    def get_status(_session_id), do: {:error, :not_found}
  end

  setup do
    previous_adapters = Application.get_env(:pincer, :channel_actions_adapters)
    previous_session_server = Application.get_env(:pincer, :channel_actions_session_server)

    Application.put_env(:pincer, :channel_actions_test_pid, self())

    Application.put_env(:pincer, :channel_actions_adapters, %{
      telegram: ChannelActionsTelegramStub,
      discord: ChannelActionsDiscordStub,
      whatsapp: ChannelActionsWhatsAppStub
    })

    Application.put_env(:pincer, :channel_actions_session_server, SessionServerStub)

    on_exit(fn ->
      Application.delete_env(:pincer, :channel_actions_test_pid)

      case previous_adapters do
        nil -> Application.delete_env(:pincer, :channel_actions_adapters)
        value -> Application.put_env(:pincer, :channel_actions_adapters, value)
      end

      case previous_session_server do
        nil -> Application.delete_env(:pincer, :channel_actions_session_server)
        value -> Application.put_env(:pincer, :channel_actions_session_server, value)
      end
    end)

    :ok
  end

  test "send_message without explicit target uses current session conversation" do
    assert {:ok, result} =
             ChannelActions.execute(
               %{"action" => "send_message", "content" => "status ping"},
               %{"session_id" => "telegram_123"}
             )

    assert result =~ "Message sent"
    assert_receive {:telegram_send, "123", "status ping"}
  end

  test "send_message with explicit channel and recipient routes to the correct adapter" do
    assert {:ok, result} =
             ChannelActions.execute(%{
               "action" => "send_message",
               "channel" => "discord",
               "recipient" => "456",
               "content" => "ship it"
             })

    assert result =~ "discord"
    assert_receive {:discord_send, "456", "ship it"}
  end

  test "send_message with target_session_id resolves recipient from session prefix" do
    assert {:ok, result} =
             ChannelActions.execute(%{
               "action" => "send_message",
               "target_session_id" => "whatsapp_551199999999",
               "content" => "deploy complete"
             })

    assert result =~ "whatsapp"
    assert_receive {:whatsapp_send, "551199999999", "deploy complete"}
  end

  test "returns a clear error when destination cannot be resolved" do
    assert {:error, message} =
             ChannelActions.execute(%{"action" => "send_message", "content" => "orphan ping"})

    assert message =~ "destination"
  end
end
