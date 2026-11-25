defmodule Pincer.Core.Session.HistoryTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Session.History
  alias PincerPorts.Structs.IncomingMessage

  defmodule StorageSpy do
    def get_messages("s-with-history"),
      do: [%{"role" => "user", "content" => "hi"}, %{"role" => "assistant", "content" => "hey"}]

    def get_messages("s-empty"), do: []

    def save_message(session_id, role, content) do
      if pid = Process.get(:history_test_pid) do
        send(pid, {:saved_message, session_id, role, content})
      end

      {:ok, %{session_id: session_id, role: role, content: content}}
    end
  end

  defmodule SessionLoggerSpy do
    def log(session_id, role, content, opts) do
      if pid = Process.get(:history_test_pid) do
        send(pid, {:logged_message, session_id, role, content, opts})
      end

      :ok
    end
  end

  defmodule MemoryStub do
    def record_session(content, opts) do
      if pid = Process.get(:history_test_pid) do
        send(pid, {:recorded_snapshot, content, opts})
      end

      case Process.get(:memory_stub_result, {:ok, %{}}) do
        {:ok, _} = ok -> ok
        {:error, _} = err -> err
      end
    end
  end

  setup do
    Process.put(:history_test_pid, self())
    on_exit(fn -> Process.delete(:history_test_pid) end)
    :ok
  end

  describe "load/3" do
    test "returns {history_with_system, false} when persisted messages exist" do
      assert {[
                %{"role" => "system", "content" => "SYS"},
                %{"role" => "user", "content" => "hi"},
                _
              ], false} = History.load("s-with-history", "SYS", storage: StorageSpy)
    end

    test "returns {[system_msg], true} when persisted messages are empty" do
      assert {[%{"role" => "system", "content" => "SYS"}], true} =
               History.load("s-empty", "SYS", storage: StorageSpy)
    end
  end

  describe "persist_user_input/4" do
    test "saves to storage and writes episodic session log" do
      assert :ok =
               History.persist_user_input("s-1", "hello world", "/tmp/ws",
                 storage: StorageSpy,
                 session_logger: SessionLoggerSpy
               )

      assert_received {:saved_message, "s-1", "user", "hello world"}
      assert_received {:logged_message, "s-1", "user", "hello world", [workspace_path: "/tmp/ws"]}
    end
  end

  describe "persist_assistant_response/3" do
    test "saves trimmed non-empty binary responses" do
      assert :ok = History.persist_assistant_response("s-1", "  answer  ", storage: StorageSpy)
      assert_received {:saved_message, "s-1", "assistant", "answer"}
    end

    test "skips blank, empty, or non-binary responses" do
      assert :ok = History.persist_assistant_response("s-1", "   \n ", storage: StorageSpy)
      assert :ok = History.persist_assistant_response("s-1", nil, storage: StorageSpy)
      refute_received {:saved_message, _, _, _}
    end
  end

  describe "build_user_message/3" do
    test "wraps plain binary text" do
      assert %{"role" => "user", "content" => "hello"} =
               History.build_user_message("hello", "/tmp/ws")
    end

    test "wraps IncomingMessage without attachments" do
      msg = IncomingMessage.new("s-1", "plain text")

      assert %{"role" => "user", "content" => "plain text"} =
               History.build_user_message(msg, "/tmp/ws")
    end

    test "preserves standard attachments in multimodal content" do
      msg =
        IncomingMessage.new("s-1",
          text: "look at this",
          attachments: [%{"type" => "image", "url" => "https://example.com/a.png"}]
        )

      assert %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => "look at this"},
                 %{"type" => "attachment", "attachment" => %{"type" => "image"}}
               ]
             } = History.build_user_message(msg, "/tmp/ws")
    end

    test "resolves workspace_file_ref attachments on download success and failure" do
      msg =
        IncomingMessage.new("s-1",
          text: "review",
          attachments: [
            %{
              "type" => "workspace_file_ref",
              "filename" => "spec.md",
              "url" => "telegram://file/doc1"
            },
            %{
              "type" => "workspace_file_ref",
              "filename" => "broken.bin",
              "url" => "telegram://file/doc2"
            },
            %{"type" => "image", "url" => "https://example.com/pic.png"}
          ]
        )

      downloader = fn
        "telegram://file/doc1", "spec.md", "/tmp/ws" -> {:ok, "incoming/spec.md"}
        "telegram://file/doc2", "broken.bin", "/tmp/ws" -> {:error, :timeout}
      end

      assert %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => text},
                 %{"type" => "attachment", "attachment" => %{"type" => "image"}}
               ]
             } = History.build_user_message(msg, "/tmp/ws", downloader: downloader)

      assert text =~ "[File received] spec.md saved to workspace at `incoming/spec.md`"
      assert text =~ "[File received] broken.bin (download failed: :timeout)"
      assert text =~ "review"
    end
  end

  describe "prune/3" do
    test "keeps history intact when non-system count is within limit" do
      history = [
        %{"role" => "system", "content" => "SYS"},
        %{"role" => "user", "content" => "m1"},
        %{"role" => "assistant", "content" => "m2"}
      ]

      assert History.prune(history, "s-1", max_messages: 2) == history
    end

    test "drops oldest non-system messages and inserts prune notice when limit exceeded" do
      history =
        [%{"role" => "system", "content" => "SYS"}] ++
          Enum.map(1..6, &%{"role" => "user", "content" => "m#{&1}"})

      pruned = History.prune(history, "s-1", max_messages: 3)

      assert [
               %{"role" => "system", "content" => "SYS"},
               %{"role" => "system", "content" => notice},
               %{"role" => "user", "content" => "m4"},
               %{"role" => "user", "content" => "m5"},
               %{"role" => "user", "content" => "m6"}
             ] = pruned

      assert notice =~ "3 earlier messages removed"
      assert notice =~ "3-message limit"
      assert notice =~ "Session: s-1"
    end
  end

  describe "swap_system_prompt/2" do
    test "replaces leading system message content" do
      history = [%{"role" => "system", "content" => "OLD"}, %{"role" => "user", "content" => "u"}]

      assert [%{"role" => "system", "content" => "NEW"}, %{"role" => "user", "content" => "u"}] ==
               History.swap_system_prompt(history, "NEW")
    end

    test "leaves history unchanged if leading message is not system" do
      history = [%{"role" => "user", "content" => "u"}]
      assert History.swap_system_prompt(history, "NEW") == history
    end
  end

  describe "record_reset_snapshot/3" do
    test "counts non-system messages and handles ok and error outcomes cleanly" do
      history = [
        %{"role" => "system", "content" => "SYS"},
        %{"role" => "user", "content" => "u1"},
        %{"role" => "assistant", "content" => "a1"}
      ]

      now = ~U[2026-11-19 12:00:00Z]

      Process.put(:memory_stub_result, {:ok, %{status: :appended}})

      assert :ok =
               History.record_reset_snapshot("s-reset", history, memory: MemoryStub, now: now)

      assert_received {:recorded_snapshot,
                       "session_id=s-reset message_count=2 reset_at=2026-11-19T12:00:00Z",
                       [session_id: "s-reset"]}

      Process.put(:memory_stub_result, {:error, :disk_full})

      assert :ok =
               History.record_reset_snapshot("s-reset", history, memory: MemoryStub, now: now)
    end
  end

  describe "content_to_text/1" do
    test "extracts text from IncomingMessage, binary, and content parts" do
      assert History.content_to_text(IncomingMessage.new("s", "from struct")) == "from struct"
      assert History.content_to_text("plain") == "plain"

      assert History.content_to_text([
               %{"text" => "part1"},
               %{"image" => "skip"},
               %{"text" => "part2"}
             ]) == "part1  part2"

      assert History.content_to_text(nil) == ""
    end
  end
end
