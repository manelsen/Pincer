defmodule Pincer.Channels.Shared.InboundTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Shared.Inbound
  alias PincerPorts.Structs.IncomingMessage

  defmodule PolicyStub do
    def allow?(:dm_access, %{sender_id: "allowed"}), do: {:allow, %{}}
    def allow?(:dm_access, %{sender_id: "blocked"}), do: {:deny, %{user_message: "DM blocked"}}
    def approve_code(:dingtalk, "allowed", "123456"), do: :ok
    def bound_agent_id(_, _), do: nil
  end

  defmodule UXStub do
    def resolve_shortcut("menu"), do: {:ok, "/menu"}
    def resolve_shortcut(_), do: :error
    def help_text(ch), do: "Menu for #{ch}"
    def unknown_command_hint, do: "Use /menu"
  end

  defmodule SessionStub do
    def reset("s-ok"), do: :ok
    def reset(_), do: {:error, :failed}

    def process_input("s-err", _msg), do: {:error, :boom}

    def process_input(sid, %IncomingMessage{} = msg) do
      send(self(), {:processed, sid, msg})
      {:ok, :started}
    end
  end

  defmodule ProjectStub do
    def kanban(sid), do: "Kanban #{sid}"
    def project(sid, args), do: "Project #{sid}: #{inspect(args)}"
  end

  describe "route/2" do
    test "ignores blank text without attachments" do
      base = %{
        channel: :dingtalk,
        text: "   ",
        session_id: "s1",
        on_command: fn _ -> flunk("must not run command") end,
        on_message: fn _ -> flunk("must not run message") end,
        on_ignored: fn reason -> send(self(), {:ignored_cb, reason}) end
      }

      assert {:ignored, :empty} = Inbound.route(base)
      assert_received {:ignored_cb, :empty}
    end

    test "enforces DM policy, notifies on_denied, and bypasses DM gate for /pair" do
      denied = %{
        channel: :dingtalk,
        text: "hi",
        sender_id: "blocked",
        is_dm: true,
        config: %{},
        session_id: "s1",
        on_command: fn _ -> flunk("must not run") end,
        on_message: fn _ -> flunk("must not run") end,
        on_denied: fn msg -> send(self(), {:denied_msg, msg}) end
      }

      assert {:denied, "DM blocked"} = Inbound.route(denied, policy_module: PolicyStub)
      assert_received {:denied_msg, "DM blocked"}

      pair_bypass =
        Map.merge(denied, %{text: "/pair 123456", on_command: fn cmd -> {:pair, cmd} end})

      assert {:command, {:pair, "/pair 123456"}} =
               Inbound.route(pair_bypass, policy_module: PolicyStub)
    end

    test "skips DM gate in group chats and routes shortcuts and projects" do
      inbound = %{
        channel: :line,
        text: "menu",
        sender_id: "blocked",
        is_dm: false,
        session_id: "s1",
        on_command: fn cmd -> {:cmd, cmd} end,
        on_message: fn text -> {:msg, text} end,
        on_project_response: fn resp, sid -> {:proj, resp, sid} end
      }

      assert {:shortcut, {:cmd, "/menu"}} =
               Inbound.route(inbound,
                 policy_module: PolicyStub,
                 resolve_shortcut: &UXStub.resolve_shortcut/1,
                 continue_project: fn _, _, _ -> :not_handled end
               )

      assert {:project, {:proj, "next", "s1"}} =
               Inbound.route(%{inbound | text: "answer"},
                 policy_module: PolicyStub,
                 resolve_shortcut: fn _ -> :error end,
                 continue_project: fn "s1", "answer", _ -> {:handled, "next"} end
               )
    end
  end

  describe "handle_standard_command/3" do
    test "handles /ping, /menu, /new, /kanban, /project, /pair, and unknown commands" do
      parent = self()

      context = %{
        channel: :dingtalk,
        session_id: "s-ok",
        sender_id: "allowed",
        is_dm: true,
        ensure_session: fn -> send(parent, :session_ensured) end,
        on_project_kickoff: fn -> send(parent, :project_kicked_off) end,
        send_reply: fn msg -> send(parent, {:reply, msg}) end
      }

      opts = [
        ux_module: UXStub,
        session_module: SessionStub,
        project_module: ProjectStub,
        policy_module: PolicyStub
      ]

      Inbound.handle_standard_command("/ping", context, opts)
      assert_received {:reply, "Pong! 🏓"}

      Inbound.handle_standard_command("/menu", context, opts)
      assert_received {:reply, "Menu for dingtalk"}

      Inbound.handle_standard_command("/new", context, opts)
      assert_received :session_ensured
      assert_received {:reply, "🔄 Session reset."}

      Inbound.handle_standard_command("/kanban", context, opts)
      assert_received {:reply, "Kanban s-ok"}

      Inbound.handle_standard_command("/project Demo", context, opts)
      assert_received {:reply, "Project s-ok: \"Demo\""}
      assert_received :project_kicked_off

      Inbound.handle_standard_command("/pair 123456", context, opts)
      assert_received {:reply, "Pairing concluido com sucesso. Agora sua DM esta autorizada."}

      Inbound.handle_standard_command("/wat", context, opts)
      assert_received {:reply, msg}
      assert msg =~ "Unknown command: /wat"
    end
  end

  describe "dispatch_session_message/3" do
    test "ensures session and worker and forwards IncomingMessage" do
      parent = self()

      assert :ok ==
               Inbound.dispatch_session_message("s-ok", "hello world",
                 session_module: SessionStub,
                 ensure_session: fn -> send(parent, :session_started) end,
                 ensure_worker: fn -> send(parent, :worker_started) end
               )

      assert_received :session_started
      assert_received :worker_started

      assert_received {:processed, "s-ok",
                       %IncomingMessage{session_id: "s-ok", text: "hello world"}}

      assert {:error, :boom} ==
               Inbound.dispatch_session_message("s-err", "hello", session_module: SessionStub)
    end
  end
end
