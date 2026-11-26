defmodule Pincer.Core.Session.BlackboardIngestorTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Session.BlackboardIngestor

  defmodule BlackboardStub do
    def fetch_new(since_id, opts) do
      if pid = Process.get(:bb_ingestor_test_pid) do
        send(pid, {:fetched, since_id, opts})
      end

      Process.get(:bb_ingestor_fetch_result, {[], since_id})
    end
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "sess-bb-1",
        blackboard_scope: "agent-1",
        last_blackboard_id: 10,
        history: [%{"role" => "system", "content" => "SYS"}],
        subagent_progress_tracker: %{},
        status: :idle
      },
      overrides
    )
  end

  setup do
    Process.put(:bb_ingestor_test_pid, self())
    on_exit(fn -> Process.delete(:bb_ingestor_test_pid) end)
    :ok
  end

  describe "poll/2" do
    test "returns {:noop, state} when no new messages exist" do
      Process.put(:bb_ingestor_fetch_result, {[], 10})
      on_exit(fn -> Process.delete(:bb_ingestor_fetch_result) end)

      state = base_state()
      assert {:noop, ^state} = BlackboardIngestor.poll(state, blackboard: BlackboardStub)
      assert_received {:fetched, 10, [scope: "agent-1"]}
    end

    test "ingests messages, updates last_blackboard_id, broadcasts notifications, and requests evaluation when idle" do
      messages = [
        %{agent_id: "sub-1", content: "Started with goal: audit"},
        %{agent_id: "sub-1", content: "FINISHED: all clear"},
        %{
          agent_id: "Architect",
          project_id: "p-1",
          kind: :plan_generated,
          content: "PLAN_GENERATED:\nTask 1"
        }
      ]

      Process.put(:bb_ingestor_fetch_result, {messages, 15})
      on_exit(fn -> Process.delete(:bb_ingestor_fetch_result) end)

      state = base_state(%{status: :idle})

      assert {:evaluate, next_state} =
               BlackboardIngestor.poll(state,
                 blackboard: BlackboardStub,
                 publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end
               )

      assert next_state.last_blackboard_id == 15
      assert length(next_state.history) == 2
      assert List.last(next_state.history)["content"] =~ "SYSTEM UPDATE (Blackboard):"
      assert List.last(next_state.history)["content"] =~ "Suggested Project Plan (p-1)"
      assert next_state.subagent_progress_tracker["sub-1"].terminal? == true
      assert_received {:published, "sess-bb-1", {:agent_status, _}}
    end

    test "returns {:ok, next_state} without evaluation when batch only contains sub-agent progress updates" do
      messages = [
        %{agent_id: "sub-1", content: "Started with goal: audit"},
        %{agent_id: "sub-1", content: "FINISHED: all clear"}
      ]

      Process.put(:bb_ingestor_fetch_result, {messages, 16})
      on_exit(fn -> Process.delete(:bb_ingestor_fetch_result) end)

      state = base_state(%{status: :idle})

      assert {:ok, next_state} =
               BlackboardIngestor.poll(state,
                 blackboard: BlackboardStub,
                 publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end
               )

      assert next_state.last_blackboard_id == 16
      assert_received {:published, "sess-bb-1", {:agent_status, _}}
    end
  end

  describe "ingest_batch/4" do
    test "skips broadcasting and evaluation when broadcast? is false" do
      messages = [
        %{agent_id: "sub-1", content: "Started with goal: audit"},
        %{agent_id: "sub-1", content: "FINISHED: done"}
      ]

      state = base_state(%{status: :idle})

      assert {:ok, next_state} =
               BlackboardIngestor.ingest_batch(messages, 22, state,
                 broadcast?: false,
                 publish_fn: fn sid, ev -> send(self(), {:published, sid, ev}) end
               )

      assert next_state.last_blackboard_id == 22
      assert length(next_state.history) == 2
      refute_received {:published, _, _}
    end

    test "returns {:ok, state} instead of {:evaluate, state} when session is working" do
      messages = [%{agent_id: "sub-1", content: "FINISHED: done"}]
      state = base_state(%{status: :working})

      assert {:ok, next_state} =
               BlackboardIngestor.ingest_batch(messages, 30, state,
                 broadcast?: true,
                 publish_fn: fn _sid, _ev -> :ok end
               )

      assert next_state.last_blackboard_id == 30
    end
  end

  describe "start_recovery_catch_up/3" do
    test "fetches missed messages asynchronously and notifies parent when non-empty" do
      messages = [%{agent_id: "sys", content: "missed"}]
      test_pid = self()

      defmodule CatchUpBlackboard do
        def fetch_new(10, scope: "agent-1"), do: {[%{agent_id: "sys", content: "missed"}], 11}
      end

      assert :ok =
               BlackboardIngestor.start_recovery_catch_up(base_state(), test_pid,
                 task_supervisor: Pincer.Core.TaskSupervisor,
                 blackboard: CatchUpBlackboard
               )

      assert_receive {:recovery_catch_up_done, ^messages, 11}, 1000
    end
  end
end
