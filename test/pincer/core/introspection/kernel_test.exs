defmodule Pincer.Core.Introspection.KernelTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Introspection.Kernel
  alias Pincer.Test.Support.SyncHelpers

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

  defmodule ReflectAndSkillLLMStub do
    def chat_completion([%{"content" => system_prompt} | _], _opts) do
      body =
        if String.contains?(system_prompt, "skill synthesis engine") do
          Jason.encode!(%{
            "name" => "kernel-auto-skill",
            "description" => "Promoted directly from introspection reflection.",
            "when_to_use" => "When running Elixir verification loops.",
            "steps" => ["Run mix format", "Run mix test --warnings-as-errors"],
            "pitfalls" => ["Avoid skipping boundary checks."]
          })
        else
          Jason.encode!(%{
            focus: "Consolidate verified practices into skills",
            concerns: [],
            open_questions: [],
            summary: "Trace reviewed and lessons consolidated."
          })
        end

      {:ok, %{"content" => body}, nil}
    end
  end

  setup do
    # Clean introspection data
    :ok = Pincer.Infra.SQLite.execute("DELETE FROM self_states")
    :ok = Pincer.Infra.SQLite.execute("DELETE FROM lessons")

    # Stop any lingering kernel for this agent
    case Registry.lookup(Kernel.Registry, @agent) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
        :ok

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

  defp eventually(fun) do
    SyncHelpers.eventually(fun, timeout: 1_000, interval: 5)
    true
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
      pid = start_kernel()
      Kernel.register_session(@agent, self())
      SyncHelpers.barrier(pid)

      # Trigger a state update to verify broadcast works
      send_tick_and_reflect(pid)
    end

    test "cleans up on session DOWN" do
      kernel_pid = start_kernel()

      {pid, ref} =
        spawn_monitor(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Kernel.register_session(@agent, pid)
      SyncHelpers.barrier(kernel_pid)

      Process.exit(pid, :kill)
      receive do: ({:DOWN, ^ref, _, _, _} -> :ok)

      # Kernel should have removed the dead session and still be alive
      eventually(fn -> not MapSet.member?(:sys.get_state(kernel_pid).session_pids, pid) end)
      assert Kernel.get_self_state(@agent) != nil
    end
  end

  describe "report_trace/2" do
    test "stores trace for reflection" do
      pid = start_kernel()
      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}]}
      Kernel.report_trace(@agent, trace)

      state = SyncHelpers.barrier(pid)
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

      state = SyncHelpers.barrier(pid)
      assert state.stall_hold_until == nil
    end
  end

  describe "report_activity/2" do
    test "transitions wakefulness to :active on :working" do
      pid = start_kernel()
      Kernel.report_activity(@agent, :working)

      state = SyncHelpers.barrier(pid)
      assert state.wakefulness == :active
    end

    test "transitions wakefulness to :idle on :idle" do
      pid = start_kernel()
      Kernel.report_activity(@agent, :working)
      SyncHelpers.barrier(pid)
      Kernel.report_activity(@agent, :idle)

      state = SyncHelpers.barrier(pid)
      assert state.wakefulness == :idle
    end
  end

  describe "tick and reflection" do
    test "triggers reflection when trace exists and throttle expired" do
      pid = start_kernel(tick_interval: 20, reflection_throttle_ms: 0)

      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)

      eventually(fn ->
        s = :sys.get_state(pid)
        s.last_reflection_at != nil and length(s.reflection_history) > 0
      end)
    end

    test "skips reflection when no trace" do
      pid = start_kernel(tick_interval: 600_000, reflection_throttle_ms: 0)
      send(pid, :tick)
      send(pid, :tick)

      state = SyncHelpers.barrier(pid)
      assert state.last_reflection_at == nil
    end

    test "skips shallow traces" do
      pid = start_kernel(tick_interval: 600_000, reflection_throttle_ms: 0)

      trace = %{"steps" => [%{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)
      send(pid, :tick)
      send(pid, :tick)

      state = SyncHelpers.barrier(pid)
      assert state.last_reflection_at == nil
    end

    test "respects throttle" do
      pid = start_kernel(tick_interval: 600_000, reflection_throttle_ms: 999_999)

      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)
      SyncHelpers.barrier(pid)

      # Manually set a recent reflection
      :sys.replace_state(pid, fn s ->
        %{s | last_reflection_at: System.system_time(:millisecond)}
      end)

      send(pid, :tick)
      send(pid, :tick)

      state = SyncHelpers.barrier(pid)
      # Should still have the manually set value, not a new one
      assert state.reflection_history == []
    end

    test "broadcasts self_state update to registered sessions" do
      _pid = start_kernel(tick_interval: 20, reflection_throttle_ms: 0)
      Kernel.register_session(@agent, self())

      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)

      assert_receive {:kernel_self_state_updated, updated_state}, 500
      assert updated_state.agent_id == @agent
    end

    test "handles reflection errors gracefully" do
      pid =
        start_kernel(
          tick_interval: 20,
          reflection_throttle_ms: 0,
          introspection_client: LLMErrorStub
        )

      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)
      assert eventually(fn -> :sys.get_state(pid).last_reflection_at != nil end)
      assert eventually(fn -> :sys.get_state(pid).pending_reflection? == false end)

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
          tick_interval: 10,
          reflection_throttle_ms: 0,
          introspection_client: LLMStallStub
        )

      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)

      eventually(fn ->
        s = :sys.get_state(pid)
        s.stall_hold_until != nil and length(s.reflection_history) >= 3
      end)
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

  defp send_tick_and_reflect(pid) do
    send(pid, :tick)
    SyncHelpers.barrier(pid)
  end

  describe "mood system" do
    test "applies mood shift on trace outcome (failure → negative valence)" do
      pid = start_kernel()
      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}]}
      Kernel.report_trace(@agent, trace)

      state = SyncHelpers.barrier(pid)
      assert state.self_state.mood_valence < 0.0
    end

    test "applies mood shift on success trace (positive valence)" do
      pid = start_kernel()

      trace = %{
        "steps" => [%{"kind" => "tool"}, %{kind: "tool"}, %{kind: "tool"}, %{kind: "llm"}]
      }

      Kernel.report_trace(@agent, trace)

      state = SyncHelpers.barrier(pid)
      assert state.self_state.mood_valence > 0.0
    end

    test "blends LLM mood from reflection" do
      pid = start_kernel(tick_interval: 20, reflection_throttle_ms: 0)

      # First set some initial mood via a trace
      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}]}
      Kernel.report_trace(@agent, trace)

      state_before = SyncHelpers.barrier(pid)
      v_before = state_before.self_state.mood_valence

      eventually(fn ->
        s = :sys.get_state(pid)
        s.last_reflection_at != nil and s.self_state.mood_valence != v_before
      end)
    end

    test "decays mood toward zero on tick" do
      pid = start_kernel(tick_interval: 600_000, reflection_throttle_ms: 999_999)

      # Set a non-zero mood
      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}]}
      Kernel.report_trace(@agent, trace)

      state = SyncHelpers.barrier(pid)
      v_after_trace = state.self_state.mood_valence

      send(pid, :tick)
      state2 = SyncHelpers.barrier(pid)
      # Mood should have moved toward zero
      assert abs(state2.self_state.mood_valence) < abs(v_after_trace)
    end
  end

  describe "skill promotion loop" do
    test "promote_skills/1 generates workspace SKILL.md and broadcasts {:kernel_skills_updated, skill}" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_kernel_promo_#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      {:ok, lesson} =
        Pincer.Core.Introspection.LessonStore.create(@agent, %{
          content: "Always run mix format and mix test before submitting patches.",
          confidence: 0.9,
          success_count: 3
        })

      start_kernel(
        workspace_path: workspace,
        introspection_client: ReflectAndSkillLLMStub,
        skill_promotion_throttle_ms: 0
      )

      Kernel.register_session(@agent, self())
      Kernel.promote_skills(@agent)

      assert_receive {:kernel_skills_updated, promoted}, 1_000
      assert promoted.name == "kernel-auto-skill"
      assert File.exists?(promoted.path)
      assert lesson.id in promoted.lesson_ids
    end

    test "reflection completion automatically promotes eligible lessons when throttle allows" do
      workspace =
        Path.join(
          System.tmp_dir!(),
          "pincer_kernel_autopromo_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace)
      on_exit(fn -> File.rm_rf(workspace) end)

      {:ok, _lesson} =
        Pincer.Core.Introspection.LessonStore.create(@agent, %{
          content: "Verify boundary exports after adding any new Core submodule.",
          confidence: 0.88,
          success_count: 2
        })

      start_kernel(
        tick_interval: 40,
        reflection_throttle_ms: 0,
        skill_promotion_throttle_ms: 0,
        workspace_path: workspace,
        introspection_client: ReflectAndSkillLLMStub
      )

      Kernel.register_session(@agent, self())
      trace = %{"steps" => [%{"kind" => "tool"}, %{"kind" => "error"}, %{"kind" => "tool"}]}
      Kernel.report_trace(@agent, trace)

      assert_receive {:kernel_self_state_updated, _updated}, 1_000
      assert_receive {:kernel_skills_updated, promoted}, 1_000
      assert File.exists?(promoted.path)
    end
  end
end
