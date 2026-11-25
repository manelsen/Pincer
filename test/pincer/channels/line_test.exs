defmodule Pincer.Channels.LineTest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.Line

  @webhook_fixture %{
    "events" => [
      %{
        "type" => "message",
        "replyToken" => "test_reply_token",
        "source" => %{"userId" => "U1234567890", "type" => "user"},
        "message" => %{"type" => "text", "text" => "Hello bot"}
      }
    ]
  }

  describe "parse_webhook_events/1" do
    test "extracts text message events from webhook payload" do
      [event] = Line.parse_webhook_events(@webhook_fixture)

      assert event.user_id == "U1234567890"
      assert event.text == "Hello bot"
      assert event.reply_token == "test_reply_token"
    end

    test "returns empty list for empty events array" do
      assert Line.parse_webhook_events(%{"events" => []}) == []
    end

    test "ignores non-text message events" do
      payload = %{
        "events" => [
          %{
            "type" => "message",
            "replyToken" => "rt_image",
            "source" => %{"userId" => "U111", "type" => "user"},
            "message" => %{"type" => "image", "id" => "img_1"}
          }
        ]
      }

      assert Line.parse_webhook_events(payload) == []
    end

    test "ignores non-message events" do
      payload = %{
        "events" => [
          %{
            "type" => "follow",
            "replyToken" => "rt_follow",
            "source" => %{"userId" => "U222", "type" => "user"}
          }
        ]
      }

      assert Line.parse_webhook_events(payload) == []
    end

    test "handles multiple text events" do
      payload = %{
        "events" => [
          %{
            "type" => "message",
            "replyToken" => "rt1",
            "source" => %{"userId" => "U111", "type" => "user"},
            "message" => %{"type" => "text", "text" => "First"}
          },
          %{
            "type" => "message",
            "replyToken" => "rt2",
            "source" => %{"userId" => "U222", "type" => "user"},
            "message" => %{"type" => "text", "text" => "Second"}
          }
        ]
      }

      events = Line.parse_webhook_events(payload)
      assert length(events) == 2
      assert Enum.at(events, 0).user_id == "U111"
      assert Enum.at(events, 1).user_id == "U222"
    end
  end

  describe "session_id/1" do
    test "formats session ID as line_ prefix with userId" do
      assert Line.session_id("U1234567890") == "line_U1234567890"
    end
  end

  describe "start_link/1" do
    test "returns :ignore when LINE_CHANNEL_ACCESS_TOKEN is nil" do
      original = System.get_env("LINE_CHANNEL_ACCESS_TOKEN")
      System.delete_env("LINE_CHANNEL_ACCESS_TOKEN")

      on_exit(fn ->
        if original do
          System.put_env("LINE_CHANNEL_ACCESS_TOKEN", original)
        else
          System.delete_env("LINE_CHANNEL_ACCESS_TOKEN")
        end
      end)

      assert Line.start_link(%{}) == :ignore
    end
  end

  describe "configured env names" do
    test "uses token_env from channel config" do
      original_config = Application.get_env(:pincer, :line_channel_config)
      env_name = "PINCER_TEST_LINE_TOKEN_#{System.unique_integer([:positive])}"
      System.put_env(env_name, "test-token")

      on_exit(fn ->
        System.delete_env(env_name)

        if original_config,
          do: Application.put_env(:pincer, :line_channel_config, original_config),
          else: Application.delete_env(:pincer, :line_channel_config)
      end)

      assert {:ok, pid} = Line.start_link(%{"token_env" => env_name})
      assert Process.alive?(pid)
      Supervisor.stop(pid)
    end

    test "uses secret_env from channel config for webhook signatures" do
      original_config = Application.get_env(:pincer, :line_channel_config)
      secret_env = "PINCER_TEST_LINE_SECRET_#{System.unique_integer([:positive])}"
      secret = "custom-line-secret"
      body = ~s({"events":[]})
      signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()
      System.put_env(secret_env, secret)
      Application.put_env(:pincer, :line_channel_config, %{"secret_env" => secret_env})

      on_exit(fn ->
        System.delete_env(secret_env)

        if original_config,
          do: Application.put_env(:pincer, :line_channel_config, original_config),
          else: Application.delete_env(:pincer, :line_channel_config)
      end)

      assert Line.handle_webhook(body, signature) == {:ok, []}
    end
  end

  describe "handles_session?/1" do
    test "matches line_ prefixed session IDs" do
      assert Line.handles_session?("line_U1234567890") == true
    end

    test "rejects non-line session IDs" do
      assert Line.handles_session?("telegram_123") == false
    end
  end

  describe "resolve_recipient/1" do
    test "extracts userId from line_ session ID" do
      assert Line.resolve_recipient("line_U1234567890") == "U1234567890"
    end

    test "returns session ID unchanged if no prefix" do
      assert Line.resolve_recipient("something_else") == "something_else"
    end
  end

  describe "inbound routing via Shared.Inbound" do
    defmodule SessionStub do
      @behaviour PincerPorts.Session

      @impl true
      def resolve(:line, ctx, _cfg) do
        %PincerPorts.Session.Context{
          channel: :line,
          session_id: "line_#{ctx.user_id}",
          root_agent_id: ctx.user_id,
          root_agent_source: :session_scope,
          workspace_path: "/tmp",
          blackboard_scope: "line_#{ctx.user_id}"
        }
      end

      @impl true
      def process_input(sid, incoming) do
        if pid = Application.get_env(:pincer, :line_test_pid),
          do: send(pid, {:line_input, sid, incoming})

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

    defmodule APIStub do
      def push_message(to, messages) do
        if pid = Application.get_env(:pincer, :line_test_pid),
          do: send(pid, {:line_push, to, messages})

        {:ok, %{}}
      end
    end

    setup do
      prev_session = Application.get_env(:pincer, :session_adapter)
      prev_cfg = Application.get_env(:pincer, :line_channel_config)
      prev_api = Application.get_env(:pincer, :line_api_module)

      Application.put_env(:pincer, :session_adapter, SessionStub)
      Application.put_env(:pincer, :line_api_module, APIStub)
      Application.put_env(:pincer, :line_test_pid, self())

      unless Process.whereis(Pincer.Channels.Line.SessionSupervisor) do
        start_supervised!(Pincer.Channels.Line.SessionSupervisor)
      end

      on_exit(fn ->
        if prev_session,
          do: Application.put_env(:pincer, :session_adapter, prev_session),
          else: Application.delete_env(:pincer, :session_adapter)

        if prev_cfg,
          do: Application.put_env(:pincer, :line_channel_config, prev_cfg),
          else: Application.delete_env(:pincer, :line_channel_config)

        if prev_api,
          do: Application.put_env(:pincer, :line_api_module, prev_api),
          else: Application.delete_env(:pincer, :line_api_module)

        Application.delete_env(:pincer, :line_test_pid)
      end)

      :ok
    end

    test "routes text events through session port" do
      Application.put_env(:pincer, :line_channel_config, %{"dm_policy" => %{"mode" => "open"}})

      assert :ok ==
               Line.handle_event(%{
                 user_id: "U123",
                 chat_id: "U123",
                 source_type: "user",
                 text: "Hello LINE"
               })

      assert_receive {:line_input, "line_U123", %{text: "Hello LINE"}}
    end

    test "blocks disabled DM access and replies via LINE API" do
      Application.put_env(:pincer, :line_channel_config, %{
        "dm_policy" => %{"mode" => "disabled"}
      })

      assert :ok ==
               Line.handle_event(%{
                 user_id: "U123",
                 chat_id: "U123",
                 source_type: "user",
                 text: "Hello LINE"
               })

      assert_receive {:line_push, "U123", [%{"type" => "text", "text" => msg}]}
      assert msg =~ "desativadas"
      refute_receive {:line_input, _, _}, 50
    end
  end
end
