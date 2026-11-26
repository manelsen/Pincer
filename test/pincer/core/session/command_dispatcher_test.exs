defmodule Pincer.Core.Session.CommandDispatcherTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Session.CommandDispatcher
  alias PincerPorts.Structs.Usage

  defmodule PreferencesSpy do
    def save_state(state) do
      send(self(), {:prefs_saved, state})
      :ok
    end
  end

  defmodule StorageSpy do
    def delete_messages(session_id) do
      send(self(), {:deleted_messages, session_id})
      :ok
    end
  end

  defmodule HistorySpy do
    def record_reset_snapshot(session_id, history) do
      send(Process.get(:cmd_test_pid, self()), {:snapshot_recorded, session_id, length(history)})
      :ok
    end
  end

  defmodule ProjectRouterStub do
    def parse("/project start demo"), do: {:ok, :start, "demo"}
    def parse("/project list"), do: {:ok, :list, nil}
    def parse(_), do: :error

    def handle_command(:start, "demo", _session_id), do: {:ok, "proj-42"}
    def handle_command(:list, nil, _session_id), do: :ok
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "sess-cmd-1",
        workspace_path: "/tmp/ws-cmd",
        history: [
          %{"role" => "system", "content" => "SYS"},
          %{"role" => "user", "content" => "hi"}
        ],
        status: :idle,
        worker_pid: nil,
        worker_ref: nil,
        pending_evals: %{},
        model_override: nil,
        thinking_level: nil,
        reasoning_visible: false,
        verbose: false,
        usage_display: "off",
        token_usage_total: %Usage{},
        input_buffer: [],
        debounce_timer: nil,
        pending_approval: nil,
        auto_approve_until: nil,
        turn_start_ms: nil
      },
      overrides
    )
  end

  describe "dispatch_call/3" do
    test "handles set_model, set_thinking, set_reasoning_visible, set_verbose, and set_usage" do
      state = base_state(%{worker_pid: self()})

      {:reply, :ok, s1} =
        CommandDispatcher.dispatch_call({:set_model, "openrouter", "claude"}, state,
          preferences_mod: PreferencesSpy
        )

      assert s1.model_override == %{provider: "openrouter", model: "claude"}
      assert_received {:model_changed, "openrouter", "claude"}
      assert_received {:prefs_saved, ^s1}

      {:reply, :ok, s2} =
        CommandDispatcher.dispatch_call({:set_thinking, "medium"}, s1,
          preferences_mod: PreferencesSpy
        )

      assert s2.thinking_level == "medium"

      {:reply, :ok, s3} =
        CommandDispatcher.dispatch_call({:set_reasoning_visible, true}, s2,
          preferences_mod: PreferencesSpy
        )

      assert s3.reasoning_visible == true

      {:reply, :ok, s4} = CommandDispatcher.dispatch_call({:set_verbose, true}, s3)
      assert s4.verbose == true

      {:reply, :ok, s5} =
        CommandDispatcher.dispatch_call({:set_usage, "tokens"}, s4,
          preferences_mod: PreferencesSpy
        )

      assert s5.usage_display == "tokens"
    end

    test "handles approve_all and notifies worker for pending approval" do
      now = ~U[2026-11-25 12:00:00Z]
      state = base_state(%{worker_pid: self(), pending_approval: {"call-7", "ls"}})

      {:reply, :ok, next_state} =
        CommandDispatcher.dispatch_call({:approve_all, 300}, state, now: now)

      assert next_state.pending_approval == nil
      assert next_state.auto_approve_until == ~U[2026-11-25 12:05:00Z]
      assert_received {:tool_approval_result, "call-7", :approved}
    end

    test "handles reset by clearing storage, resetting history, and optionally triggering bootstrap" do
      state = base_state(%{status: :working, turn_start_ms: 123})

      {:reply, :ok, next_state} =
        CommandDispatcher.dispatch_call(:reset, state,
          storage: StorageSpy,
          history_mod: HistorySpy,
          task_supervisor: Pincer.Core.TaskSupervisor,
          prompt_builder: fn _s -> "NEW SYS" end,
          bootstrap_check: fn _ws -> true end,
          self_pid: self()
        )

      assert_received {:deleted_messages, "sess-cmd-1"}
      assert_received :trigger_bootstrap
      assert next_state.history == [%{"role" => "system", "content" => "NEW SYS"}]
      assert next_state.status == :idle
      assert next_state.turn_start_ms == nil
    end
  end

  describe "approval helpers" do
    test "handle_approval_required auto-approves or stores pending and publishes UI event" do
      now = ~U[2026-11-25 12:00:00Z]
      future = ~U[2026-11-25 12:10:00Z]

      auto_state = base_state(%{worker_pid: self(), auto_approve_until: future})

      assert auto_state ==
               CommandDispatcher.handle_approval_required("c1", "ls", auto_state,
                 now: now,
                 publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end
               )

      assert_received {:tool_approval_result, "c1", :approved}
      refute_received {:published, _, _}

      pending_state = base_state()

      updated =
        CommandDispatcher.handle_approval_required("c2", "rm -rf /tmp/x", pending_state,
          now: now,
          publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end
        )

      assert updated.pending_approval == {"c2", "rm -rf /tmp/x"}
      assert_received {:published, "sess-cmd-1", {:approval_ui, "c2", "rm -rf /tmp/x"}}
    end

    test "handle_pending_approval_input resolves decision or re-prompts" do
      state = base_state(%{worker_pid: self(), pending_approval: {"c3", "ls"}})

      assert {:reply, {:ok, :approval_sent}, cleared} =
               CommandDispatcher.handle_pending_approval_input({"c3", "ls"}, "aprovo", state)

      assert cleared.pending_approval == nil
      assert_received {:tool_approval_result, "c3", :approved}

      assert {:reply, {:ok, :buffered}, ^state} =
               CommandDispatcher.handle_pending_approval_input({"c3", "ls"}, "talvez", state,
                 publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end
               )

      assert_received {:published, "sess-cmd-1", {:agent_status, msg}}
      assert msg =~ "Aprovação pendente"
    end
  end

  describe "handle_cancel/2" do
    test "stops alive worker, clears input buffer, and returns :stopped" do
      pid = spawn(fn -> Process.sleep(5_000) end)

      state =
        base_state(%{
          status: :working,
          worker_pid: pid,
          input_buffer: ["queued"],
          turn_start_ms: 99
        })

      assert {:reply, {:ok, :stopped}, next_state} =
               CommandDispatcher.handle_cancel(state,
                 task_supervisor: Pincer.Core.TaskSupervisor,
                 publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end
               )

      assert next_state.status == :idle
      assert next_state.worker_pid == nil
      assert next_state.input_buffer == []
      assert next_state.turn_start_ms == nil
      refute Process.alive?(pid)
      assert_received {:published, "sess-cmd-1", {:agent_response, msg}}
      assert msg =~ "cancelada"
    end

    test "returns :idle when no worker is alive" do
      state = base_state()
      assert {:reply, {:ok, :idle}, ^state} = CommandDispatcher.handle_cancel(state)
    end
  end

  describe "dispatch_project_command/3" do
    test "executes matched project command asynchronously and publishes response" do
      state = base_state()
      test_pid = self()

      assert {:handled, ^state} =
               CommandDispatcher.dispatch_project_command("/project start demo", state,
                 project_router: ProjectRouterStub,
                 task_supervisor: Pincer.Core.TaskSupervisor,
                 publish_fn: fn sid, ev -> send(test_pid, {:published, sid, ev}) end
               )

      assert_receive {:published, "sess-cmd-1", {:agent_response, msg}}, 1000
      assert msg =~ "proj-42"

      assert :not_a_command ==
               CommandDispatcher.dispatch_project_command("regular chat", state,
                 project_router: ProjectRouterStub
               )
    end
  end
end
