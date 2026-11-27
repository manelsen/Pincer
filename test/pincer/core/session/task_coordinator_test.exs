defmodule Pincer.Core.Session.TaskCoordinatorTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Session.TaskCoordinator
  alias PincerPorts.Structs.Usage

  defmodule KernelSpy do
    def get_lesson_ids(agent_id) do
      send(self(), {:kernel_get_lessons, agent_id})
      ["lesson-1"]
    end

    def report_activity(agent_id, status) do
      send(self(), {:kernel_activity, agent_id, status})
      :ok
    end

    def report_trace(agent_id, trace) do
      send(self(), {:kernel_trace, agent_id, trace})
      :ok
    end
  end

  defmodule TelemetrySpy do
    def emit_conversation_turn_start(session_id) do
      send(self(), {:telemetry_turn_start, session_id})
      1234
    end

    def emit_conversation_turn_stop(session_id, start_ms, meta) do
      send(self(), {:telemetry_turn_stop, session_id, start_ms, meta})
      :ok
    end

    def emit_conversation_error(session_id, reason) do
      send(self(), {:telemetry_error, session_id, reason})
      :ok
    end
  end

  defmodule HistorySpy do
    def persist_assistant_response(session_id, response) do
      send(self(), {:persisted_assistant, session_id, response})
      :ok
    end

    def prune(history, _session_id), do: history
  end

  defmodule PreferencesSpy do
    def save_state(state) do
      send(self(), {:prefs_saved, state.session_id, state.token_usage_total})
      :ok
    end
  end

  defmodule LessonStoreSpy do
    def record_outcome(id, outcome) do
      send(Process.get(:lesson_test_pid, self()), {:lesson_outcome, id, outcome})
      :ok
    end
  end

  defmodule ExecutorStub do
    def run(parent, session_id, history, opts) do
      send(parent, {:executor_ran, session_id, history, opts})
      {:ok, history, "done", nil}
    end
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "sess-tc-1",
        root_agent_id: "agent-tc-1",
        workspace_path: "/tmp/ws-tc",
        history: [%{"role" => "system", "content" => "SYS"}],
        status: :idle,
        worker_pid: nil,
        worker_ref: nil,
        pending_evals: %{},
        model_override: %{provider: "test", model: "m1"},
        thinking_level: "high",
        reasoning_visible: false,
        usage_display: "off",
        token_usage_total: %Usage{},
        llm_client: nil,
        injected_lesson_ids: [],
        last_executor_trace: nil,
        turn_start_ms: nil
      },
      overrides
    )
  end

  describe "model_override_with_thinking/1" do
    test "merges thinking_level into map model_override when present" do
      assert %{provider: "test", model: "m1", thinking_level: "high"} ==
               TaskCoordinator.model_override_with_thinking(base_state())

      assert %{provider: "test", model: "m1"} ==
               TaskCoordinator.model_override_with_thinking(base_state(%{thinking_level: nil}))

      assert nil ==
               TaskCoordinator.model_override_with_thinking(base_state(%{model_override: nil}))
    end
  end

  describe "start_turn/3" do
    test "spawns supervised executor task and updates worker state" do
      test_pid = self()
      history = [%{"role" => "user", "content" => "hi"}]

      state =
        TaskCoordinator.start_turn(base_state(), history,
          task_supervisor: Pincer.Core.TaskSupervisor,
          executor: ExecutorStub,
          kernel: KernelSpy,
          telemetry: TelemetrySpy,
          parent: test_pid
        )

      assert state.status == :working
      assert is_pid(state.worker_pid)
      assert is_reference(state.worker_ref)
      assert state.turn_start_ms == 1234
      assert state.injected_lesson_ids == ["lesson-1"]
      assert_received {:telemetry_turn_start, "sess-tc-1"}
      assert_received {:kernel_activity, "agent-tc-1", :working}

      assert_receive {:executor_ran, "sess-tc-1", ^history, opts}, 1000
      assert opts[:model_override] == %{provider: "test", model: "m1", thinking_level: "high"}
      assert opts[:workspace_path] == "/tmp/ws-tc"

      # Flush task completion message
      ref = state.worker_ref
      assert_receive {^ref, {:ok, ^history, "done", nil}}, 1000
    end
  end

  describe "handle_task_message/3" do
    test "correlates executor completion, accumulates usage, persists, and resets worker fields" do
      ref = make_ref()

      state =
        base_state(%{
          status: :working,
          worker_pid: self(),
          worker_ref: ref,
          turn_start_ms: 1000
        })

      final_history = state.history ++ [%{"role" => "assistant", "content" => "ok"}]
      usage = %{"prompt_tokens" => 5, "completion_tokens" => 7}

      assert {:handled, next_state} =
               TaskCoordinator.handle_task_message(
                 {ref, {:ok, final_history, "ok", usage}},
                 state,
                 publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end,
                 kernel: KernelSpy,
                 telemetry: TelemetrySpy,
                 history_mod: HistorySpy,
                 preferences_mod: PreferencesSpy
               )

      assert next_state.status == :idle
      assert next_state.worker_pid == nil
      assert next_state.worker_ref == nil
      assert next_state.turn_start_ms == nil

      assert next_state.token_usage_total == %Usage{
               prompt_tokens: 5,
               completion_tokens: 7,
               total_tokens: 12
             }

      assert_received {:persisted_assistant, "sess-tc-1", "ok"}
      assert_received {:published, "sess-tc-1", {:agent_response, "ok", ^usage}}
      assert_received {:kernel_activity, "agent-tc-1", :idle}

      assert_received {:telemetry_turn_stop, "sess-tc-1", 1000,
                       %{prompt_tokens: 5, completion_tokens: 7}}

      assert_received {:prefs_saved, "sess-tc-1", _}
    end

    test "handles executor error and worker crash cleanly" do
      ref = make_ref()

      state =
        base_state(%{status: :working, worker_pid: self(), worker_ref: ref, turn_start_ms: 99})

      assert {:handled, next_state} =
               TaskCoordinator.handle_task_message(
                 {ref, {:error, :boom}},
                 state,
                 publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end,
                 kernel: KernelSpy,
                 telemetry: TelemetrySpy
               )

      assert next_state.status == :idle
      assert next_state.worker_pid == nil
      assert next_state.worker_ref == nil
      assert next_state.turn_start_ms == nil
      assert_received {:telemetry_error, "sess-tc-1", :boom}
      assert_received {:kernel_activity, "agent-tc-1", :idle}
      assert_received {:published, "sess-tc-1", {:agent_response, msg}}
      assert msg =~ "❌"
    end

    test "handles pending_evals reply, ignore, error, and DOWN" do
      r1 = make_ref()
      r2 = make_ref()
      r3 = make_ref()
      r4 = make_ref()

      state =
        base_state(%{
          pending_evals: %{
            r1 => :bootstrap,
            r2 => :blackboard,
            r3 => :blackboard,
            r4 => :blackboard
          }
        })

      assert {:handled, s1} =
               TaskCoordinator.handle_task_message(
                 {r1, {:reply, "hi", %{"prompt_tokens" => 2, "completion_tokens" => 3}}},
                 state,
                 publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end,
                 history_mod: HistorySpy,
                 preferences_mod: PreferencesSpy
               )

      refute Map.has_key?(s1.pending_evals, r1)
      assert List.last(s1.history) == %{"role" => "assistant", "content" => "hi"}
      assert_received {:published, "sess-tc-1", {:agent_response, "hi", _}}

      assert {:handled, s2} = TaskCoordinator.handle_task_message({r2, :ignore}, s1)
      refute Map.has_key?(s2.pending_evals, r2)

      assert {:handled, s3} = TaskCoordinator.handle_task_message({r3, {:error, :oops}}, s2)
      refute Map.has_key?(s3.pending_evals, r3)

      assert {:handled, s4} =
               TaskCoordinator.handle_task_message({:DOWN, r4, :process, self(), :killed}, s3)

      assert s4.pending_evals == %{}
    end

    test "returns :ignore for stale or unrecognized messages" do
      state = base_state()

      assert :ignore ==
               TaskCoordinator.handle_task_message({make_ref(), {:ok, [], "x", nil}}, state)

      assert :ignore == TaskCoordinator.handle_task_message(:unrelated, state)
    end
  end

  describe "stop_worker/2 and clear_pending_evals/1" do
    test "clears worker fields and pending evals" do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(pid)
      eval_ref = make_ref()

      state =
        base_state(%{
          worker_pid: pid,
          worker_ref: ref,
          pending_evals: %{eval_ref => :blackboard}
        })

      stopped =
        state
        |> TaskCoordinator.stop_worker(task_supervisor: Pincer.Core.TaskSupervisor)
        |> TaskCoordinator.clear_pending_evals()

      assert stopped.worker_pid == nil
      assert stopped.worker_ref == nil
      assert stopped.pending_evals == %{}
      refute Process.alive?(pid)
    end
  end

  describe "worker notifications and trace recording" do
    test "sends model_changed and approval result to alive worker" do
      state = base_state(%{worker_pid: self()})

      assert :ok == TaskCoordinator.notify_model_changed(state, "openai", "gpt-4o")
      assert_received {:model_changed, "openai", "gpt-4o"}

      assert :ok == TaskCoordinator.send_approval_decision(state, "call-1", :approved)
      assert_received {:tool_approval_result, "call-1", :approved}
    end

    test "records trace and clears injected_lesson_ids" do
      trace = %{"steps" => [%{"kind" => "error"}]}
      state = base_state(%{injected_lesson_ids: ["l-1"]})

      next_state =
        TaskCoordinator.record_trace(state, trace,
          kernel: KernelSpy,
          lesson_store: LessonStoreSpy,
          task_supervisor: Pincer.Core.TaskSupervisor
        )

      assert next_state.last_executor_trace == trace
      assert next_state.injected_lesson_ids == []
      assert_received {:kernel_trace, "agent-tc-1", ^trace}
    end

    test "forwards session_model_override via report_trace/3 when supported without mutating trace" do
      defmodule KernelV3Spy do
        def report_trace(agent_id, trace, opts) do
          send(self(), {:kernel_trace_v3, agent_id, trace, opts})
          :ok
        end
      end

      trace = %{"steps" => [%{"kind" => "tool"}]}

      state =
        base_state(%{
          injected_lesson_ids: [],
          model_override: %{provider: "ollama", model: "llama3.2"}
        })

      next_state =
        TaskCoordinator.record_trace(state, trace,
          kernel: KernelV3Spy,
          lesson_store: LessonStoreSpy,
          task_supervisor: Pincer.Core.TaskSupervisor
        )

      assert next_state.last_executor_trace == trace

      assert_received {:kernel_trace_v3, "agent-tc-1", ^trace,
                       [session_model_override: %{provider: "ollama", model: "llama3.2"}]}
    end
  end
end
