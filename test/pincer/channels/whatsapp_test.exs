defmodule Pincer.Channels.WhatsAppTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Pincer.Channels.WhatsApp
  alias Pincer.Core.ProjectOrchestrator

  defmodule FakeBridge do
    @behaviour Pincer.Channels.WhatsApp.Bridge
    use Agent

    @impl true
    def start_link(opts) do
      owner = Keyword.fetch!(opts, :owner)
      config = Keyword.get(opts, :config, %{})
      test_pid = config["test_pid"] || config[:test_pid]

      Agent.start_link(fn ->
        %{
          owner: owner,
          test_pid: test_pid
        }
      end)
    end

    @impl true
    def send_message(pid, chat_id, text) do
      test_pid = Agent.get(pid, & &1.test_pid)

      if is_pid(test_pid) do
        send(test_pid, {:bridge_send, chat_id, text})
      end

      :ok
    end

    def emit(pid, event) do
      owner = Agent.get(pid, & &1.owner)
      send(owner, {:whatsapp_bridge_event, event})
      :ok
    end
  end

  defmodule FailingBridge do
    @behaviour Pincer.Channels.WhatsApp.Bridge

    @impl true
    def start_link(_opts), do: {:error, :bridge_unavailable}

    @impl true
    def send_message(_pid, _chat_id, _text), do: {:error, :bridge_unavailable}
  end

  setup do
    stop_channel()

    on_exit(fn ->
      stop_channel()
      ProjectOrchestrator.reset("whatsapp_551199111111")
      ProjectOrchestrator.reset("whatsapp_551199222222")
    end)

    :ok
  end

  describe "startup" do
    test "returns :ignore when bridge cannot start" do
      assert :ignore == WhatsApp.start_link(%{"bridge_module" => FailingBridge})
    end
  end

  describe "command routing" do
    test "project shortcut starts wizard and captures follow-up text" do
      {:ok, channel_pid} =
        WhatsApp.start_link(%{
          "bridge_module" => FakeBridge,
          "test_pid" => self()
        })

      bridge_pid = bridge_pid!(channel_pid)
      chat_id = "551199111111"

      FakeBridge.emit(bridge_pid, incoming_message(chat_id, "project"))

      assert_receive {:bridge_send, ^chat_id, first_response}, 500
      assert first_response =~ "Project Manager"
      assert first_response =~ "objetivo principal"

      FakeBridge.emit(bridge_pid, incoming_message(chat_id, "Comprar parafusadeira"))

      assert_receive {:bridge_send, ^chat_id, second_response}, 500
      assert second_response =~ "tipo do projeto"
    end

    test "plain kanban shortcut routes to /kanban" do
      {:ok, channel_pid} =
        WhatsApp.start_link(%{
          "bridge_module" => FakeBridge,
          "test_pid" => self()
        })

      bridge_pid = bridge_pid!(channel_pid)
      chat_id = "551199111111"

      FakeBridge.emit(bridge_pid, incoming_message(chat_id, "kanban"))

      assert_receive {:bridge_send, ^chat_id, response}, 500
      assert response =~ "Kanban unavailable for this session"
      assert response =~ "/project"
    end
  end

  describe "message processing" do
    test "routes plain text to session pipeline when not collecting project" do
      test_pid = self()

      {:ok, channel_pid} =
        WhatsApp.start_link(%{
          "bridge_module" => FakeBridge,
          "test_pid" => test_pid,
          "ensure_session_started_fn" => fn session_id ->
            send(test_pid, {:ensure_session_started, session_id})
            :ok
          end,
          "ensure_channel_session_fn" => fn chat_id, session_id ->
            send(test_pid, {:ensure_channel_session, chat_id, session_id})
            :ok
          end,
          "process_input_fn" => fn session_id, text ->
            send(test_pid, {:process_input, session_id, text})
            {:ok, :started}
          end
        })

      bridge_pid = bridge_pid!(channel_pid)
      chat_id = "551199222222"

      FakeBridge.emit(bridge_pid, incoming_message(chat_id, "Mensagem normal"))

      assert_receive {:ensure_session_started, "whatsapp_551199222222"}, 500
      assert_receive {:ensure_channel_session, ^chat_id, "whatsapp_551199222222"}, 500
      assert_receive {:process_input, "whatsapp_551199222222", "Mensagem normal"}, 500
    end

    test "applies dm policy and blocks disabled direct messages" do
      test_pid = self()

      {:ok, channel_pid} =
        WhatsApp.start_link(%{
          "bridge_module" => FakeBridge,
          "test_pid" => test_pid,
          "dm_policy" => %{"mode" => "disabled"},
          "process_input_fn" => fn _session_id, _text ->
            send(test_pid, :process_input_called)
            {:ok, :started}
          end
        })

      bridge_pid = bridge_pid!(channel_pid)
      chat_id = "551199222222"

      FakeBridge.emit(bridge_pid, incoming_message(chat_id, "Pode responder?"))

      assert_receive {:bridge_send, ^chat_id, denial}, 500
      assert denial =~ "desativadas"
      refute_receive :process_input_called, 100
    end

    test "splits long outbound messages into safe WhatsApp chunks" do
      {:ok, _channel_pid} =
        WhatsApp.start_link(%{
          "bridge_module" => FakeBridge,
          "test_pid" => self()
        })

      chat_id = "551199222222"
      long_text = String.duplicate("a", 7600)

      assert :ok = WhatsApp.send_message(chat_id, long_text)

      assert_receive {:bridge_send, ^chat_id, chunk1}, 500
      assert_receive {:bridge_send, ^chat_id, chunk2}, 500
      assert_receive {:bridge_send, ^chat_id, chunk3}, 500
      refute_receive {:bridge_send, ^chat_id, _extra}, 80

      assert String.length(chunk1) <= 3500
      assert String.length(chunk2) <= 3500
      assert String.length(chunk3) <= 3500
      assert chunk1 <> chunk2 <> chunk3 == long_text
    end
  end

  describe "qr pairing guidance" do
    test "logs scan instructions and ascii qr when bridge emits qr event" do
      {:ok, channel_pid} =
        WhatsApp.start_link(%{
          "bridge_module" => FakeBridge,
          "test_pid" => self()
        })

      bridge_pid = bridge_pid!(channel_pid)

      log =
        capture_log(fn ->
          FakeBridge.emit(bridge_pid, %{
            "type" => "qr",
            "qr" => "mock-qr-payload",
            "ascii" => "██\n██"
          })

          Process.sleep(40)
        end)

      assert log =~ "Aparelhos conectados"
      assert log =~ "Conectar um aparelho"
      assert log =~ "██"
    end

    test "logs keyboard pairing instructions when bridge emits pairing_code event" do
      {:ok, channel_pid} =
        WhatsApp.start_link(%{
          "bridge_module" => FakeBridge,
          "test_pid" => self()
        })

      bridge_pid = bridge_pid!(channel_pid)

      log =
        capture_log(fn ->
          FakeBridge.emit(bridge_pid, %{
            "type" => "pairing_code",
            "phone" => "55****0111",
            "code" => "ABCD-EFGH"
          })

          Process.sleep(40)
        end)

      assert log =~ "Pairing code ready"
      assert log =~ "Conectar com numero de telefone"
      assert log =~ "ABCD-EFGH"
    end

    test "logs explicit QR fallback guidance on pairing_code_failed bridge error" do
      {:ok, channel_pid} =
        WhatsApp.start_link(%{
          "bridge_module" => FakeBridge,
          "test_pid" => self()
        })

      bridge_pid = bridge_pid!(channel_pid)

      log =
        capture_log(fn ->
          FakeBridge.emit(bridge_pid, %{
            "type" => "error",
            "reason" => "pairing_code_failed",
            "details" => %{
              "phone" => "55****5154",
              "message" => "Connection Closed"
            }
          })

          Process.sleep(40)
        end)

      assert log =~ "Pairing code failed for 55****5154"
      assert log =~ "Fallback to QR is active"
      assert log =~ "Aparelhos conectados -> Conectar um aparelho"
      assert log =~ "sessions/whatsapp/last_qr.txt"
      assert log =~ "qrencode -t ANSIUTF8 <"
    end
  end

  defp stop_channel do
    case Process.whereis(Pincer.Channels.WhatsApp) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp bridge_pid!(channel_pid) do
    channel_pid
    |> :sys.get_state()
    |> Map.fetch!(:bridge_pid)
  end

  defp incoming_message(chat_id, text) do
    %{
      "type" => "message",
      "chat_id" => chat_id,
      "sender_id" => chat_id,
      "is_group" => false,
      "text" => text
    }
  end
end
