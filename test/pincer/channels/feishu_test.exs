defmodule Pincer.Channels.FeishuTest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.Feishu

  @webhook_fixture %{
    "schema" => "2.0",
    "event" => %{
      "sender" => %{"sender_id" => %{"open_id" => "ou_test123"}},
      "message" => %{
        "chat_id" => "oc_test_chat",
        "message_id" => "om_test_msg",
        "message_type" => "text",
        "chat_type" => "p2p",
        "content" => Jason.encode!(%{"text" => "Hello from Feishu"})
      }
    }
  }

  describe "parse_webhook_event/1" do
    test "extracts all fields from a valid payload" do
      result = Feishu.parse_webhook_event(@webhook_fixture)

      assert result == %{
               open_id: "ou_test123",
               chat_id: "oc_test_chat",
               message_id: "om_test_msg",
               content: "Hello from Feishu",
               msg_type: "text",
               chat_type: "p2p"
             }
    end

    test "returns :error for malformed payload" do
      assert Feishu.parse_webhook_event(%{}) == :error
    end

    test "returns :error for nil" do
      assert Feishu.parse_webhook_event(nil) == :error
    end

    test "returns :error for payload missing event key" do
      assert Feishu.parse_webhook_event(%{"schema" => "2.0"}) == :error
    end

    test "returns raw content JSON when text key is absent" do
      payload =
        put_in(
          @webhook_fixture,
          ["event", "message", "content"],
          Jason.encode!(%{"image_key" => "img_123"})
        )

      result = Feishu.parse_webhook_event(payload)
      assert result.content == Jason.encode!(%{"image_key" => "img_123"})
    end
  end

  describe "format_session_id/1" do
    test "prefixes open_id with feishu_" do
      assert Feishu.format_session_id("ou_abc123") == "feishu_ou_abc123"
    end
  end

  describe "validate_webhook/4" do
    test "delegates to WebhookVerifier" do
      # Verify delegation by calling with values that should fail validation
      result = Feishu.validate_webhook("ts", "nonce", "body", "bad_sig")
      assert result == {:error, :invalid_signature}
    end
  end

  describe "start_link/1 (:ignore when env vars missing)" do
    test "returns :ignore when FEISHU_APP_ID is nil" do
      original_app_id = System.get_env("FEISHU_APP_ID")
      original_app_secret = System.get_env("FEISHU_APP_SECRET")

      System.delete_env("FEISHU_APP_ID")
      System.put_env("FEISHU_APP_SECRET", "secret")

      assert Feishu.start_link(%{}) == :ignore

      if original_app_id, do: System.put_env("FEISHU_APP_ID", original_app_id)
      if original_app_secret, do: System.put_env("FEISHU_APP_SECRET", original_app_secret)
    end

    test "returns :ignore when FEISHU_APP_SECRET is nil" do
      original_app_id = System.get_env("FEISHU_APP_ID")
      original_app_secret = System.get_env("FEISHU_APP_SECRET")

      System.put_env("FEISHU_APP_ID", "app_id")
      System.delete_env("FEISHU_APP_SECRET")

      assert Feishu.start_link(%{}) == :ignore

      if original_app_id, do: System.put_env("FEISHU_APP_ID", original_app_id)
      if original_app_secret, do: System.put_env("FEISHU_APP_SECRET", original_app_secret)
    end

    test "returns :ignore when both env vars are nil" do
      original_app_id = System.get_env("FEISHU_APP_ID")
      original_app_secret = System.get_env("FEISHU_APP_SECRET")

      System.delete_env("FEISHU_APP_ID")
      System.delete_env("FEISHU_APP_SECRET")

      assert Feishu.start_link(%{}) == :ignore

      if original_app_id, do: System.put_env("FEISHU_APP_ID", original_app_id)
      if original_app_secret, do: System.put_env("FEISHU_APP_SECRET", original_app_secret)
    end
  end

  describe "inbound routing via Shared.Inbound" do
    defmodule SessionStub do
      @behaviour PincerPorts.Session

      @impl true
      def resolve(:feishu, ctx, _cfg) do
        %PincerPorts.Session.Context{
          channel: :feishu,
          session_id: "feishu_#{ctx.open_id}",
          root_agent_id: ctx.open_id,
          root_agent_source: :session_scope,
          workspace_path: "/tmp",
          blackboard_scope: "feishu_#{ctx.open_id}"
        }
      end

      @impl true
      def process_input(sid, incoming) do
        if pid = Application.get_env(:pincer, :feishu_test_pid),
          do: send(pid, {:feishu_input, sid, incoming})

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
      def send_message(chat_id, content, msg_type) do
        if pid = Application.get_env(:pincer, :feishu_test_pid),
          do: send(pid, {:feishu_msg, chat_id, content, msg_type})

        {:ok, %{}}
      end
    end

    setup do
      prev_session = Application.get_env(:pincer, :session_adapter)
      prev_cfg = Application.get_env(:pincer, :feishu_channel_config)
      prev_api = Application.get_env(:pincer, :feishu_api_module)

      Application.put_env(:pincer, :session_adapter, SessionStub)
      Application.put_env(:pincer, :feishu_api_module, APIStub)
      Application.put_env(:pincer, :feishu_test_pid, self())

      unless Process.whereis(Pincer.Channels.Feishu.SessionSupervisor) do
        start_supervised!(Pincer.Channels.Feishu.SessionSupervisor)
      end

      on_exit(fn ->
        if prev_session,
          do: Application.put_env(:pincer, :session_adapter, prev_session),
          else: Application.delete_env(:pincer, :session_adapter)

        if prev_cfg,
          do: Application.put_env(:pincer, :feishu_channel_config, prev_cfg),
          else: Application.delete_env(:pincer, :feishu_channel_config)

        if prev_api,
          do: Application.put_env(:pincer, :feishu_api_module, prev_api),
          else: Application.delete_env(:pincer, :feishu_api_module)

        Application.delete_env(:pincer, :feishu_test_pid)
      end)

      :ok
    end

    test "routes text events through session port" do
      Application.put_env(:pincer, :feishu_channel_config, %{"dm_policy" => %{"mode" => "open"}})

      assert :ok ==
               Feishu.handle_event(%{
                 open_id: "ou_123",
                 chat_id: "oc_123",
                 content: "Hello Feishu",
                 chat_type: "p2p"
               })

      assert_receive {:feishu_input, "feishu_ou_123", %{text: "Hello Feishu"}}
    end

    test "blocks disabled DM access and replies via Feishu API" do
      Application.put_env(:pincer, :feishu_channel_config, %{
        "dm_policy" => %{"mode" => "disabled"}
      })

      assert :ok ==
               Feishu.handle_event(%{
                 open_id: "ou_123",
                 chat_id: "oc_123",
                 content: "Hello Feishu",
                 chat_type: "p2p"
               })

      assert_receive {:feishu_msg, "oc_123", payload, "text"}
      assert payload =~ "desativadas"
      refute_receive {:feishu_input, _, _}, 50
    end
  end
end
