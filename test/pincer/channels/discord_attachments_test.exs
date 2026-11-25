defmodule Pincer.Channels.DiscordAttachmentsTest do
  use ExUnit.Case, async: false

  alias PincerPorts.Session.Context

  @session_id "discord:attachment-test"

  # Discord routes inbound messages through the session port, so the whole
  # media path can be exercised without the Core session stack.
  defmodule SessionStub do
    @behaviour PincerPorts.Session

    @session_id "discord:attachment-test"

    @impl true
    def resolve(:discord, _context, _config) do
      %Context{
        channel: :discord,
        session_id: @session_id,
        root_agent_id: "attachment-test",
        root_agent_source: :session_scope,
        workspace_path: "/tmp",
        blackboard_scope: @session_id
      }
    end

    @impl true
    def process_input(session_id, input) do
      notify({:process_input, session_id, input})
      :ok
    end

    @impl true
    def get_status(_sid), do: :ok
    @impl true
    def reset(_sid), do: :ok
    @impl true
    def set_model(_sid, _provider, _model), do: :ok
    @impl true
    def set_thinking(_sid, _level), do: :ok
    @impl true
    def set_reasoning_visible(_sid, _visible), do: :ok
    @impl true
    def set_verbose(_sid, _verbose), do: :ok
    @impl true
    def set_usage(_sid, _level), do: :ok
    @impl true
    def approve_all(_sid, _seconds), do: :ok
    @impl true
    def start_session(_sid, _opts), do: :ok
    @impl true
    def stop_session(_sid), do: :ok
    @impl true
    def ensure_started(_sid, _opts), do: {:ok, self()}

    defp notify(message) do
      case Application.get_env(:pincer, :test_notify_pid) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end
  end

  setup do
    previous_adapter = Application.get_env(:pincer, :session_adapter)
    previous_config = Application.get_env(:pincer, :discord_channel_config)

    Application.put_env(:pincer, :session_adapter, SessionStub)

    Application.put_env(:pincer, :discord_channel_config, %{
      "dm_policy" => %{"mode" => "open"}
    })

    Application.put_env(:pincer, :test_notify_pid, self())

    on_exit(fn ->
      if previous_adapter,
        do: Application.put_env(:pincer, :session_adapter, previous_adapter),
        else: Application.delete_env(:pincer, :session_adapter)

      if previous_config,
        do: Application.put_env(:pincer, :discord_channel_config, previous_config),
        else: Application.delete_env(:pincer, :discord_channel_config)

      Application.delete_env(:pincer, :test_notify_pid)
    end)

    unless Process.whereis(Pincer.Channels.Discord.SessionSupervisor) do
      start_supervised!(Pincer.Channels.Discord.SessionSupervisor)
    end

    :ok
  end

  describe "inbound attachments" do
    test "a captioned image arrives as text plus an attachment reference" do
      attachment = %{
        filename: "photo.png",
        url: "https://cdn.example.test/photo.png",
        size: 1234
      }

      send_message("veja isso", [attachment])

      assert_receive {:process_input, @session_id, incoming}, 1_000

      assert incoming.text == "veja isso"
      assert [ref] = incoming.attachments
      assert ref["type"] == "attachment_ref"
      assert ref["url"] == attachment.url
      assert ref["mime_type"] == "image/png"
      assert ref["filename"] == "photo.png"
      assert ref["size"] == 1234
    end

    test "an image without a caption is still delivered" do
      attachment = %{
        filename: "diagram.webp",
        url: "https://cdn.example.test/diagram.webp",
        size: 42
      }

      send_message("", [attachment])

      assert_receive {:process_input, @session_id, incoming}, 1_000

      assert incoming.text in [nil, ""]
      assert [ref] = incoming.attachments
      assert ref["url"] == attachment.url
      assert ref["mime_type"] == "image/webp"
    end

    test "a plain text message keeps its text and carries no attachments" do
      send_message("bom dia", [])

      assert_receive {:process_input, @session_id, incoming}, 1_000

      assert incoming.text == "bom dia"
      assert incoming.attachments == []
    end
  end

  defp send_message(content, attachments) do
    message = %{
      author: %{bot: false, id: "42", username: "tester"},
      content: content,
      channel_id: 456,
      guild_id: nil,
      attachments: attachments
    }

    Pincer.Channels.Discord.Consumer.handle_event({:MESSAGE_CREATE, message, nil})
  end
end
