defmodule Pincer.Core.Introspection.KernelTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Introspection.Kernel

  @agent "kernel_test_agent"

  defmodule LLMReflectStub do
    def chat_completion(_messages, _opts) do
      body =
        Jason.encode!(%{
          focus: "Improve error handling",
          concerns: ["Timeouts increasing"],
          open_questions: ["Should we add retries?"],
          summary: "The last execution had transient errors.",
          mood_valence: 0.4,
          mood_arousal: 0.6
        })

      {:ok, %{"content" => body}, nil}
    end
  end

  defmodule LLMStallStub do
    def chat_completion(_messages, _opts) do
      body =
        Jason.encode!(%{
          focus: "Same focus every time",
          concerns: [],
          open_questions: [],
          summary: "Identical summary"
        })

      {:ok, %{"content" => body}, nil}
    end
  end

  defmodule LLMErrorStub do
    def chat_completion(_messages, _opts), do: {:error, :timeout}
  end

  setup do
    # Clean introspection data
    Pincer.Infra.Repo.delete_all(Pincer.Core.Introspection.Schema)
    Pincer.Infra.Repo.delete_all(Pincer.Core.Introspection.LessonSchema)

    # Stop any lingering kernel for this agent
    case Registry.lookup(Kernel.Registry, @agent) do
      [{pid, _}] ->
        GenServer.stop(pid, :normal, 1000)

      [] ->
        :ok
    end

    :ok
  end

  defp start_kernel(opts \\ []) do
    defaults = [
      agent_id: @agent,
      tick_interval: 600_000,
      introspection_client: LLMReflectStub
    ]

    start_supervised!({Kernel, Keyword.merge(defaults, opts)})
  end

  describe "lifecycle" do
    test "starts and registers via Registry" do
      pid = start_kernel()
      assert [{^pid, _}] = Registry.lookup(Kernel.Registry, @agent)
    end

    test "loads self_state on init" do
      start_kernel()
      self_state = Kernel.get_self_state(@agent)
      assert self_state != nil
      assert self_state.agent_id == @agent
    end
  end

  describe "ensure_started/1" do
    test "is idempotent" do
      pid = start_kernel()
      assert {:ok, ^pid} = Kernel.ensure_started(@agent)
    end
  end

  describe "session registration" do
    test "registers and monitors a session PID" do
      start_kernel()
      Kernel.register_session(@agent, self())
      # Give cast time to process
      Process.sleep(20)

      # Trigger a state update to verify broadcast works
      send_tick_and_reflect()
    end

    test "cleans up on session DOWN" do
      kernel_pid = start_kernel()
      {pid, ref} = spawn_monitor(fn -> Process.sleep(:infinity) end)

      Kernel.register_session(@agent, pid)
      Process.sleep(20)

      Process.exit(pid, :kill)
      receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
      Process.sleep(50)

      # Kernel should have removed the dead session and still be alive
      state = :sys.get_state(kernel_pid)
      refute MapSet.member?(state.session_pids, pid)
      assert Kernel.get_self_state(@agent) != nil
    end
  end

  describe "report_trace/2" do
    test "stores trace for reflection" do
      pid = start_kernel()
      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}]}
      Kernel.report_trace(@agent, trace)
      Process.sleep(20)

      state = :sys.get_state(pid)
      assert state.last_trace == trace
    end

    test "clears stall hold on non-shallow trace" do
      pid = start_kernel()

      # Set artificial stall hold
      :sys.replace_state(pid, fn s ->
        %{s | stall_hold_until: System.system_time(:millisecond) + 999_999}
      end)

      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)
      Process.sleep(20)

      state = :sys.get_state(pid)
      assert state.stall_hold_until == nil
    end
  end

  describe "report_activity/2" do
    test "transitions wakefulness to :active on :working" do
      pid = start_kernel()
      Kernel.report_activity(@agent, :working)
      Process.sleep(20)

      state = :sys.get_state(pid)
      assert state.wakefulness == :active
    end

    test "transitions wakefulness to :idle on :idle" do
      pid = start_kernel()
      Kernel.report_activity(@agent, :working)
      Process.sleep(10)
      Kernel.report_activity(@agent, :idle)
      Process.sleep(20)

      state = :sys.get_state(pid)
      assert state.wakefulness == :idle
    end
  end

  describe "tick and reflection" do
    test "triggers reflection when trace exists and throttle expired" do
      pid = start_kernel(tick_interval: 50, reflection_throttle_ms: 0)

      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)
      # Wait for tick + reflection task
      Process.sleep(200)

      state = :sys.get_state(pid)
      assert state.last_reflection_at != nil
      assert length(state.reflection_history) > 0
    end

    test "skips reflection when no trace" do
      pid = start_kernel(tick_interval: 50, reflection_throttle_ms: 0)
      Process.sleep(150)

      state = :sys.get_state(pid)
      assert state.last_reflection_at == nil
    end

    test "skips shallow traces" do
      pid = start_kernel(tick_interval: 50, reflection_throttle_ms: 0)

      trace = %{"steps" => [%{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)
      Process.sleep(200)

      state = :sys.get_state(pid)
      assert state.last_reflection_at == nil
    end

    test "respects throttle" do
      pid = start_kernel(tick_interval: 50, reflection_throttle_ms: 999_999)

      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)

      # Manually set a recent reflection
      :sys.replace_state(pid, fn s ->
        %{s | last_reflection_at: System.system_time(:millisecond)}
      end)

      Process.sleep(150)

      state = :sys.get_state(pid)
      # Should still have the manually set value, not a new one
      assert state.reflection_history == []
    end

    test "broadcasts self_state update to registered sessions" do
      _pid = start_kernel(tick_interval: 50, reflection_throttle_ms: 0)
      Kernel.register_session(@agent, self())

      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)

      assert_receive {:kernel_self_state_updated, updated_state}, 500
      assert updated_state.agent_id == @agent
    end

    test "handles reflection errors gracefully" do
      pid =
        start_kernel(
          tick_interval: 50,
          reflection_throttle_ms: 0,
          introspection_client: LLMErrorStub
        )

      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)
      Process.sleep(200)

      state = :sys.get_state(pid)
      # Should have recorded the attempt but not crashed
      assert state.last_reflection_at != nil
      assert state.pending_reflection? == false
    end
  end

  describe "stall detection" do
    test "enters stall hold after 3 identical reflections" do
      pid =
        start_kernel(
          tick_interval: 30,
          reflection_throttle_ms: 0,
          introspection_client: LLMStallStub
        )

      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)

      # Wait for 3+ reflection cycles
      Process.sleep(500)

      state = :sys.get_state(pid)
      assert state.stall_hold_until != nil
      assert length(state.reflection_history) >= 3
    end
  end

  describe "get_lesson_ids/1" do
    test "returns empty list when no lessons" do
      start_kernel()
      assert Kernel.get_lesson_ids(@agent) == []
    end

    test "returns lesson IDs when lessons exist" do
      start_kernel()

      {:ok, lesson} =
        Pincer.Core.Introspection.LessonStore.create(@agent, %{
          content: "Always validate inputs.",
          confidence: 0.8
        })

      ids = Kernel.get_lesson_ids(@agent)
      assert lesson.id in ids
    end
  end

  defp send_tick_and_reflect do
    # Helper — just ensure kernel doesn't crash
    Process.sleep(50)
  end

  describe "mood system" do
    test "applies mood shift on trace outcome (failure → negative valence)" do
      pid = start_kernel()
      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}]}
      Kernel.report_trace(@agent, trace)
      Process.sleep(30)

      state = :sys.get_state(pid)
      assert state.self_state.mood_valence < 0.0
    end

    test "applies mood shift on success trace (positive valence)" do
      pid = start_kernel()

      trace = %{
        "steps" => [%{"kind" => "tool"}, %{kind: "tool"}, %{kind: "tool"}, %{kind: "llm"}]
      }

      Kernel.report_trace(@agent, trace)
      Process.sleep(30)

      state = :sys.get_state(pid)
      assert state.self_state.mood_valence > 0.0
    end

    test "blends LLM mood from reflection" do
      pid = start_kernel(tick_interval: 50, reflection_throttle_ms: 0)

      # First set some initial mood via a trace
      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}]}
      Kernel.report_trace(@agent, trace)
      Process.sleep(30)

      state_before = :sys.get_state(pid)
      v_before = state_before.self_state.mood_valence

      # Wait for reflection which returns mood_valence: 0.4, mood_arousal: 0.6
      Process.sleep(200)

      state_after = :sys.get_state(pid)
      # Should have blended (0.7 * current + 0.3 * 0.4)
      assert state_after.self_state.mood_valence != v_before
    end

    test "decays mood toward zero on tick" do
      pid = start_kernel(tick_interval: 50, reflection_throttle_ms: 999_999)

      # Set a non-zero mood
      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}]}
      Kernel.report_trace(@agent, trace)
      Process.sleep(30)

      state = :sys.get_state(pid)
      v_after_trace = state.self_state.mood_valence

      # Wait for ticks to decay
      Process.sleep(150)

      state2 = :sys.get_state(pid)
      # Mood should have moved toward zero
      assert abs(state2.self_state.mood_valence) < abs(v_after_trace)
    end
  end
end
