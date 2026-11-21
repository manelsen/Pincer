defmodule Pincer.Channels.Shared.InboundTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Shared.Inbound

  defp inbound(overrides) do
    Map.merge(
      %{
        text: "hello",
        has_attachments: false,
        session_id: "s1",
        on_command: fn cmd -> {:ran_command, cmd} end,
        on_message: fn content -> {:ran_message, content} end,
        on_project_response: fn response, sid -> {:project_reply, response, sid} end
      },
      overrides
    )
  end

  describe "slash commands" do
    test "wins over shortcuts and projects" do
      opts = [
        resolve_shortcut: fn _ -> flunk("shortcut must not run") end,
        continue_project: fn _, _, _ -> flunk("project must not run") end
      ]

      assert {:command, {:ran_command, "/help"}} =
               Inbound.dispatch(inbound(%{text: "/help"}), opts)
    end

    test "does not treat an attached payload as a command" do
      assert {:message, {:ran_message, "/notacommand"}} =
               Inbound.dispatch(inbound(%{text: "/notacommand", has_attachments: true}))
    end
  end

  describe "shortcuts" do
    test "resolve to the command handler" do
      opts = [resolve_shortcut: fn "model" -> {:ok, "/model"} end]

      assert {:shortcut, {:ran_command, "/model"}} =
               Inbound.dispatch(inbound(%{text: "model"}), opts)
    end

    test "fall through to the message handler when unknown" do
      opts = [resolve_shortcut: fn _ -> :error end]
      assert {:message, {:ran_message, "hi"}} = Inbound.dispatch(inbound(%{text: "hi"}), opts)
    end
  end

  describe "project collection" do
    test "a handled wizard response routes to on_project_response" do
      opts = [continue_project: fn "s1", "scope", _ -> {:handled, "Got it"} end]

      assert {:project, {:project_reply, "Got it", "s1"}} =
               Inbound.dispatch(inbound(%{text: "scope"}), opts)
    end

    test "not_handled continues to the message handler" do
      opts = [continue_project: fn _, _, _ -> :not_handled end]
      assert {:message, {:ran_message, "x"}} = Inbound.dispatch(inbound(%{text: "x"}), opts)
    end

    test "is skipped when the caller supplies no project handler" do
      assert {:message, {:ran_message, "x"}} = Inbound.dispatch(inbound(%{text: "x"}), [])
    end

    test "is skipped when the session id is unknown" do
      opts = [continue_project: fn _, _, _ -> flunk("must not run without a session") end]

      assert {:message, {:ran_message, "x"}} =
               Inbound.dispatch(inbound(%{text: "x", session_id: nil}), opts)
    end
  end

  describe "attachments and empty payloads" do
    test "attachment-only payloads go straight to the message handler" do
      opts = [resolve_shortcut: fn _ -> flunk("no text to resolve") end]
      parts = [%{"type" => "image", "attachment" => %{"ref" => "a1"}}]

      # The adapter prepares the payload; the pipeline forwards it untouched.
      inbound =
        inbound(%{
          text: nil,
          has_attachments: true,
          on_message: fn content ->
            {:ran_message, content}
          end
        })

      inbound = Map.put(inbound, :payload, parts)

      assert {:message, {:ran_message, nil}} = Inbound.dispatch(inbound, opts)
    end

    test "attachments alongside text still count as attachments" do
      opts = [resolve_shortcut: fn _ -> flunk("must not resolve") end]

      assert {:message, {:ran_message, "caption"}} =
               Inbound.dispatch(inbound(%{text: "caption", has_attachments: true}), opts)
    end

    test "unsupported payloads are ignored and report the reason" do
      inbound =
        inbound(%{
          text: nil,
          has_attachments: false,
          on_ignored: fn reason -> send(self(), {:ig, reason}) end
        })

      assert {:ignored, :unsupported} = Inbound.dispatch(inbound)
      assert_received {:ig, :unsupported}
    end

    test "ignoring without a callback is silent" do
      assert {:ignored, :unsupported} = Inbound.dispatch(inbound(%{text: nil}))
    end
  end

  describe "helpers" do
    test "slash_command?/1" do
      assert Inbound.slash_command?("/help")
      assert Inbound.slash_command?("   /help")
      refute Inbound.slash_command?("help")
      refute Inbound.slash_command?(nil)
    end

    test "split_command/1" do
      assert Inbound.split_command("/think high") == {"/think", "high"}
      assert Inbound.split_command("/help") == {"/help", ""}
      assert Inbound.split_command("  /a b  c ") == {"/a", "b  c"}
    end
  end
end
