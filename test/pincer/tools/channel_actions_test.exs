defmodule Pincer.Adapters.Tools.ChannelActionsTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Tools.ChannelActions

  defmodule ChannelActionsTelegramStub do
    def send_message(recipient, content, opts \\ []) do
      send(test_pid(), {:telegram_send, recipient, content, opts})
      {:ok, 101}
    end

    defp test_pid do
      Application.fetch_env!(:pincer, :channel_actions_test_pid)
    end
  end

  defmodule ChannelActionsDiscordStub do
    def send_message(recipient, content, opts \\ []) do
      send(test_pid(), {:discord_send, recipient, content, opts})
      {:ok, 202}
    end

    defp test_pid do
      Application.fetch_env!(:pincer, :channel_actions_test_pid)
    end
  end

  defmodule ChannelActionsWhatsAppStub do
    def send_message(recipient, content, opts \\ []) do
      send(test_pid(), {:whatsapp_send, recipient, content, opts})
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
    assert_receive {:telegram_send, "123", "status ping", []}
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
    assert_receive {:discord_send, "456", "ship it", []}
  end

  test "send_message with target_session_id resolves recipient from session prefix" do
    assert {:ok, result} =
             ChannelActions.execute(%{
               "action" => "send_message",
               "target_session_id" => "whatsapp_551199999999",
               "content" => "deploy complete"
             })

    assert result =~ "whatsapp"
    assert_receive {:whatsapp_send, "551199999999", "deploy complete", []}
  end

  test "returns a clear error when destination cannot be resolved" do
    assert {:error, message} =
             ChannelActions.execute(%{"action" => "send_message", "content" => "orphan ping"})

    assert message =~ "destination"
  end

  # ---------------------------------------------------------------------------
  # send_file
  # ---------------------------------------------------------------------------

  test "send_file uploads file binary to the adapter" do
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "pincer_ca_test_#{:rand.uniform(9999)}.txt")
    File.write!(path, "hello file")
    basename = Path.basename(path)

    assert {:ok, result} =
             ChannelActions.execute(
               %{
                 "action" => "send_file",
                 "path" => basename,
                 "channel" => "discord",
                 "recipient" => "789"
               },
               %{"workspace_path" => tmp}
             )

    assert result =~ basename
    assert result =~ "discord"

    assert_receive {:discord_send, "789", "", opts}
    files = Keyword.get(opts, :files, [])
    assert [%{name: ^basename, body: "hello file"}] = files
  after
    File.rm(Path.join(System.tmp_dir!(), "pincer_ca_test_*.txt"))
  end

  test "send_file with caption sends caption text" do
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "pincer_ca_cap_#{:rand.uniform(9999)}.txt")
    File.write!(path, "data")
    basename = Path.basename(path)

    ChannelActions.execute(
      %{
        "action" => "send_file",
        "path" => basename,
        "caption" => "my caption",
        "channel" => "telegram",
        "recipient" => "123"
      },
      %{"workspace_path" => tmp}
    )

    assert_receive {:telegram_send, "123", "my caption", _opts}
  end

  test "send_file for non-existent file returns error" do
    assert {:error, msg} =
             ChannelActions.execute(
               %{
                 "action" => "send_file",
                 "path" => "no_such_file.txt",
                 "channel" => "discord",
                 "recipient" => "789"
               },
               %{"workspace_path" => System.tmp_dir!()}
             )

    assert msg =~ "not found"
  end

  test "send_file without path returns error" do
    assert {:error, msg} =
             ChannelActions.execute(%{
               "action" => "send_file",
               "channel" => "discord",
               "recipient" => "789"
             })

    assert msg =~ "path"
  end

  test "send_file to whatsapp returns unsupported error" do
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "pincer_ca_wa_#{:rand.uniform(9999)}.txt")
    File.write!(path, "data")

    assert {:error, msg} =
             ChannelActions.execute(
               %{
                 "action" => "send_file",
                 "path" => Path.basename(path),
                 "channel" => "whatsapp",
                 "recipient" => "551199"
               },
               %{"workspace_path" => tmp}
             )

    assert msg =~ "not supported"
  end

  # ---------------------------------------------------------------------------
  # reply_to
  # ---------------------------------------------------------------------------

  test "reply_to sends message with reply_to_message_id opt via telegram" do
    assert {:ok, result} =
             ChannelActions.execute(
               %{
                 "action" => "reply_to",
                 "content" => "got it",
                 "message_id" => "42",
                 "target_session_id" => "telegram_123"
               }
             )

    assert result =~ "Reply sent"
    assert result =~ "42"

    assert_receive {:telegram_send, "123", "got it", opts}
    assert Keyword.get(opts, :reply_to_message_id) == "42"
  end

  test "reply_to via discord passes reply_to_message_id opt" do
    ChannelActions.execute(%{
      "action" => "reply_to",
      "content" => "ack",
      "message_id" => "99",
      "channel" => "discord",
      "recipient" => "456"
    })

    assert_receive {:discord_send, "456", "ack", opts}
    assert Keyword.get(opts, :reply_to_message_id) == "99"
  end

  test "reply_to without content returns error" do
    assert {:error, msg} =
             ChannelActions.execute(%{
               "action" => "reply_to",
               "message_id" => "1",
               "channel" => "telegram",
               "recipient" => "123"
             })

    assert msg =~ "content"
  end

  test "reply_to without message_id returns error" do
    assert {:error, msg} =
             ChannelActions.execute(%{
               "action" => "reply_to",
               "content" => "hello",
               "channel" => "telegram",
               "recipient" => "123"
             })

    assert msg =~ "message_id"
  end
end
