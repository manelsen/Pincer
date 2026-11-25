defmodule Pincer.Channels.SlackTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Channels.Slack
  alias Pincer.Channels.Slack.APIMock

  setup do
    Application.put_env(:pincer, :slack_api, Pincer.Channels.Slack.APIMock)

    on_exit(fn ->
      Application.put_env(:pincer, :slack_api, Pincer.Channels.TestAdapter)
    end)

    verify_on_exit!()
    :ok
  end

  describe "markdown_to_mrkdwn/1" do
    test "converte negrito de Markdown para Slack asterisk" do
      # Em slack.ex temos: String.replace(~r/\*\*(.*?)\*\*/, "*\\1*")
      assert Slack.markdown_to_mrkdwn("**bold**") == "*bold*"
    end

    test "converte links para formato Slack" do
      assert Slack.markdown_to_mrkdwn("[Pincer](https://pincer.ai)") ==
               "<https://pincer.ai|Pincer>"
    end
  end

  describe "send_message/2" do
    test "envia mensagem via API do Slack" do
      channel_id = "C12345"
      text = "**olá slack**"
      token = "fake_token"

      System.put_env("SLACK_BOT_TOKEN", token)

      APIMock
      |> expect(:post, fn "chat.postMessage", ^token, payload ->
        assert payload.channel == channel_id
        assert payload.text == "*olá slack*"
        {:ok, %{ts: "1234567890.123456"}}
      end)

      assert Slack.send_message(channel_id, text) == {:ok, "1234567890.123456"}
    end
  end

  describe "update_message/3" do
    test "instancia edição via API do Slack" do
      channel_id = "C12345"
      mid = "1234567890.123456"
      text = "editado"
      token = "fake_token"

      System.put_env("SLACK_BOT_TOKEN", token)

      APIMock
      |> expect(:post, fn "chat.update", ^token, payload ->
        assert payload.channel == channel_id
        assert payload.ts == mid
        assert payload.text == text
        {:ok, %{}}
      end)

      assert Slack.update_message(channel_id, mid, text) == :ok
    end
  end

  describe "event handling via Shared.Inbound" do
    defmodule SessionStub do
      @behaviour PincerPorts.Session

      @impl true
      def resolve(:slack, _ctx, _cfg) do
        %PincerPorts.Session.Context{
          channel: :slack,
          session_id: "slack_C1",
          root_agent_id: "U1",
          root_agent_source: :session_scope,
          workspace_path: "/tmp",
          blackboard_scope: "slack_C1"
        }
      end

      @impl true
      def process_input(sid, incoming) do
        if pid = Application.get_env(:pincer, :slack_test_pid),
          do: send(pid, {:slack_input, sid, incoming})

        {:ok, :started}
      end

      @impl true
      def ensure_started(_sid, _opts), do: {:ok, self()}
      @impl true
      def start_session(_sid, _opts), do: {:ok, self()}
      @impl true
      def stop_session(_sid), do: :ok
      @impl true
      def reset(_sid), do: :ok
      @impl true
      def get_status(_sid), do: {:ok, %{}}
      @impl true
      def set_model(_sid, _p, _m), do: :ok
      @impl true
      def set_thinking(_sid, _l), do: :ok
      @impl true
      def set_reasoning_visible(_sid, _v), do: :ok
      @impl true
      def set_verbose(_sid, _v), do: :ok
      @impl true
      def set_usage(_sid, _l), do: :ok
      @impl true
      def approve_all(_sid, _s), do: :ok
    end

    setup do
      prev_session = Application.get_env(:pincer, :session_adapter)
      prev_cfg = Application.get_env(:pincer, :slack_channel_config)

      Application.put_env(:pincer, :session_adapter, SessionStub)
      Application.put_env(:pincer, :slack_test_pid, self())

      unless Process.whereis(Pincer.Channels.Slack.Registry) do
        start_supervised!({Registry, [keys: :unique, name: Pincer.Channels.Slack.Registry]})
      end

      unless Process.whereis(Pincer.Channels.Slack.SessionSupervisor) do
        start_supervised!(Pincer.Channels.Slack.SessionSupervisor)
      end

      on_exit(fn ->
        if prev_session,
          do: Application.put_env(:pincer, :session_adapter, prev_session),
          else: Application.delete_env(:pincer, :session_adapter)

        if prev_cfg,
          do: Application.put_env(:pincer, :slack_channel_config, prev_cfg),
          else: Application.delete_env(:pincer, :slack_channel_config)

        Application.delete_env(:pincer, :slack_test_pid)
      end)

      :ok
    end

    test "routes channel message through session port" do
      Application.put_env(:pincer, :slack_channel_config, %{"dm_policy" => %{"mode" => "open"}})

      assert :ok ==
               Slack.Handler.handle_event(
                 "message",
                 %{"text" => "Hello Slack", "user" => "U1", "channel" => "C123"},
                 %{}
               )

      assert_receive {:slack_input, "slack_C123", %{text: "Hello Slack"}}
    end

    test "blocks disabled DM access and handles /ping command" do
      System.put_env("SLACK_BOT_TOKEN", "fake_token")

      Application.put_env(:pincer, :slack_channel_config, %{
        "dm_policy" => %{"mode" => "disabled"}
      })

      APIMock
      |> expect(:post, fn "chat.postMessage", "fake_token", payload ->
        assert payload.channel == "D123"
        assert payload.text =~ "desativadas"
        {:ok, %{ts: "1"}}
      end)
      |> expect(:post, fn "chat.postMessage", "fake_token", payload ->
        assert payload.channel == "C123"
        assert payload.text == "Pong! 🏓"
        {:ok, %{ts: "2"}}
      end)

      assert :ok ==
               Slack.Handler.handle_event(
                 "message",
                 %{"text" => "secret dm", "user" => "U1", "channel" => "D123"},
                 %{}
               )

      refute_receive {:slack_input, _, _}, 50

      assert :ok ==
               Slack.Handler.handle_event(
                 "message",
                 %{"text" => "/ping", "user" => "U1", "channel" => "C123"},
                 %{}
               )
    end
  end
end
