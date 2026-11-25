defmodule Pincer.Channels.DingTalkTest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.DingTalk

  @webhook_fixture %{
    "msgtype" => "text",
    "text" => %{"content" => "Hello from DingTalk"},
    "senderStaffId" => "user123",
    "conversationId" => "cid_test"
  }

  describe "parse_webhook_event/1" do
    test "extracts fields correctly from text webhook payload" do
      result = DingTalk.parse_webhook_event(@webhook_fixture)

      assert result.staff_id == "user123"
      assert result.conversation_id == "cid_test"
      assert result.text == "Hello from DingTalk"
      assert result.msg_type == "text"
    end

    test "falls back to senderId when senderStaffId is missing" do
      payload = %{
        "msgtype" => "text",
        "text" => %{"content" => "Hello"},
        "senderId" => "fallback_user",
        "conversationId" => "cid_456"
      }

      result = DingTalk.parse_webhook_event(payload)
      assert result.staff_id == "fallback_user"
    end

    test "falls back to messageType when msgtype is missing" do
      payload = %{
        "messageType" => "richText",
        "text" => %{"content" => "Rich"},
        "senderStaffId" => "u1",
        "conversationId" => "cid_789"
      }

      result = DingTalk.parse_webhook_event(payload)
      assert result.msg_type == "richText"
    end

    test "returns :error for malformed payload missing conversationId" do
      assert DingTalk.parse_webhook_event(%{"msgtype" => "text"}) == :error
    end

    test "returns :error for non-map payload" do
      assert DingTalk.parse_webhook_event(nil) == :error
      assert DingTalk.parse_webhook_event("string") == :error
    end

    test "returns :error when senderStaffId and senderId are both missing" do
      payload = %{
        "msgtype" => "text",
        "text" => %{"content" => "Hello"},
        "conversationId" => "cid_test"
      }

      assert DingTalk.parse_webhook_event(payload) == :error
    end
  end

  describe "format_session_id/1" do
    test "returns dingtalk_ prefixed session ID" do
      assert DingTalk.format_session_id("user123") == "dingtalk_user123"
    end

    test "handles empty string" do
      assert DingTalk.format_session_id("") == "dingtalk_"
    end
  end

  describe "start_link/1" do
    test "returns :ignore when DINGTALK_CLIENT_ID is nil" do
      original_id = System.get_env("DINGTALK_CLIENT_ID")
      original_secret = System.get_env("DINGTALK_CLIENT_SECRET")
      System.delete_env("DINGTALK_CLIENT_ID")

      on_exit(fn ->
        if original_id,
          do: System.put_env("DINGTALK_CLIENT_ID", original_id),
          else: System.delete_env("DINGTALK_CLIENT_ID")

        if original_secret,
          do: System.put_env("DINGTALK_CLIENT_SECRET", original_secret),
          else: System.delete_env("DINGTALK_CLIENT_SECRET")
      end)

      assert DingTalk.start_link(%{}) == :ignore
    end

    test "returns :ignore when DINGTALK_CLIENT_SECRET is nil" do
      original_id = System.get_env("DINGTALK_CLIENT_ID")
      original_secret = System.get_env("DINGTALK_CLIENT_SECRET")
      System.delete_env("DINGTALK_CLIENT_SECRET")

      on_exit(fn ->
        if original_id,
          do: System.put_env("DINGTALK_CLIENT_ID", original_id),
          else: System.delete_env("DINGTALK_CLIENT_ID")

        if original_secret,
          do: System.put_env("DINGTALK_CLIENT_SECRET", original_secret),
          else: System.delete_env("DINGTALK_CLIENT_SECRET")
      end)

      assert DingTalk.start_link(%{}) == :ignore
    end
  end

  describe "handles_session?/1" do
    test "matches dingtalk_ prefixed session IDs" do
      assert DingTalk.handles_session?("dingtalk_user123") == true
    end

    test "rejects non-dingtalk session IDs" do
      assert DingTalk.handles_session?("line_U1234567890") == false
      assert DingTalk.handles_session?("telegram_123") == false
    end
  end

  describe "resolve_recipient/1" do
    test "extracts staff_id from dingtalk_ session ID" do
      assert DingTalk.resolve_recipient("dingtalk_user123") == "user123"
    end

    test "returns session ID unchanged if no prefix match" do
      assert DingTalk.resolve_recipient("something_else") == "something_else"
    end
  end

  describe "inbound routing via Shared.Inbound" do
    defmodule SessionStub do
      @behaviour PincerPorts.Session

      @impl true
      def resolve(:dingtalk, ctx, _cfg) do
        %PincerPorts.Session.Context{
          channel: :dingtalk,
          session_id: "dingtalk_#{ctx.staff_id}",
          root_agent_id: ctx.staff_id,
          root_agent_source: :session_scope,
          workspace_path: "/tmp",
          blackboard_scope: "dingtalk_#{ctx.staff_id}"
        }
      end

      @impl true
      def process_input(sid, incoming) do
        if pid = Application.get_env(:pincer, :dingtalk_test_pid),
          do: send(pid, {:dingtalk_input, sid, incoming})

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
      def send_dm(ids, msg_param, msg_key) do
        if pid = Application.get_env(:pincer, :dingtalk_test_pid),
          do: send(pid, {:dingtalk_dm, ids, msg_param, msg_key})

        {:ok, %{}}
      end
    end

    setup do
      prev_session = Application.get_env(:pincer, :session_adapter)
      prev_cfg = Application.get_env(:pincer, :dingtalk_channel_config)
      prev_api = Application.get_env(:pincer, :dingtalk_api_module)

      Application.put_env(:pincer, :session_adapter, SessionStub)
      Application.put_env(:pincer, :dingtalk_api_module, APIStub)
      Application.put_env(:pincer, :dingtalk_test_pid, self())

      unless Process.whereis(Pincer.Channels.DingTalk.SessionSupervisor) do
        start_supervised!(Pincer.Channels.DingTalk.SessionSupervisor)
      end

      on_exit(fn ->
        if prev_session,
          do: Application.put_env(:pincer, :session_adapter, prev_session),
          else: Application.delete_env(:pincer, :session_adapter)

        if prev_cfg,
          do: Application.put_env(:pincer, :dingtalk_channel_config, prev_cfg),
          else: Application.delete_env(:pincer, :dingtalk_channel_config)

        if prev_api,
          do: Application.put_env(:pincer, :dingtalk_api_module, prev_api),
          else: Application.delete_env(:pincer, :dingtalk_api_module)

        Application.delete_env(:pincer, :dingtalk_test_pid)
      end)

      :ok
    end

    test "routes plain text messages through session port" do
      Application.put_env(:pincer, :dingtalk_channel_config, %{"dm_policy" => %{"mode" => "open"}})

      assert :ok ==
               DingTalk.handle_event(%{
                 staff_id: "u123",
                 conversation_id: "dm_conv",
                 text: "Hello world",
                 msg_type: "text"
               })

      assert_receive {:dingtalk_input, "dingtalk_u123", %{text: "Hello world"}}
    end

    test "blocks disabled DM access and replies via API" do
      Application.put_env(:pincer, :dingtalk_channel_config, %{
        "dm_policy" => %{"mode" => "disabled"}
      })

      assert :ok ==
               DingTalk.handle_event(%{
                 staff_id: "u123",
                 conversation_id: "dm_conv",
                 text: "Hello world",
                 msg_type: "text"
               })

      assert_receive {:dingtalk_dm, ["u123"], payload, "sampleText"}
      assert payload =~ "desativadas"
      refute_receive {:dingtalk_input, _, _}, 50
    end
  end
end
