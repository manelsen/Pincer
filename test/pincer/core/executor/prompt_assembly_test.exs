defmodule Pincer.Core.Executor.PromptAssemblyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Introspection.Schema
  alias Pincer.Core.Executor.PromptAssembly

  defmodule StorageStub do
    def list_recent_learnings(3) do
      [
        %{type: :learning, summary: "Use web_fetch for plain URL reading"},
        %{type: :error, tool: "browser", error: "browser pool unavailable"}
      ]
    end
  end

  defmodule RecallStub do
    def build(_history, _opts) do
      %{prompt_block: "\n### MEMORY RECALL\n- [memory] previous preference"}
    end
  end

  defmodule LLMStub do
    def provider_config("stub_provider"), do: %{context_window: 10_000}
    def provider_config(_provider), do: nil
  end

  test "prepare injects temporal context, narrative memory, learnings, and recall into system prompt" do
    history = [
      %{"role" => "system", "content" => "System base"},
      %{"role" => "user", "content" => "Oi"}
    ]

    prompt_history =
      PromptAssembly.prepare(history, %{provider: "stub_provider", model: "x"},
        current_time: "2026-03-14 00:00:00Z",
        long_term_memory: "User prefers concise answers.",
        workspace_path: "/tmp/pincer_prompt_assembly",
        storage: StorageStub,
        memory_recall: RecallStub,
        llm_client: LLMStub,
        context_strategy: nil
      )

    [system_msg | _] = prompt_history
    content = system_msg["content"]

    assert content =~ "System base"
    assert content =~ "CURRENT TIME: 2026-03-14 00:00:00Z"
    assert content =~ "NARRATIVE MEMORY"
    assert content =~ "User prefers concise answers."
    assert content =~ "RECENT LEARNINGS & ERRORS"
    assert content =~ "Use web_fetch for plain URL reading"
    assert content =~ "browser pool unavailable"
    assert content =~ "MEMORY RECALL"
    assert content =~ "previous preference"
  end

  test "prepare ignores process dictionary fallbacks when opts are omitted" do
    tmp = Path.join(System.tmp_dir!(), "pincer_pa_pd_#{System.unique_integer([:positive])}")
    pincer_dir = Path.join(tmp, ".pincer")
    File.mkdir_p!(pincer_dir)
    File.write!(Path.join(pincer_dir, "MEMORY.md"), "WS_SECRET_MEMORY")

    Process.put(:long_term_memory, "PD_SECRET_MEMORY")
    Process.put(:workspace_path, tmp)

    on_exit(fn ->
      Process.delete(:long_term_memory)
      Process.delete(:workspace_path)
      File.rm_rf!(tmp)
    end)

    history = [
      %{"role" => "system", "content" => "System base"},
      %{"role" => "user", "content" => "Oi"}
    ]

    [system_msg | _] =
      PromptAssembly.prepare(history, %{provider: "stub_provider", model: "x"},
        current_time: "2026-03-14 00:00:00Z",
        storage: StorageStub,
        memory_recall: RecallStub,
        llm_client: LLMStub
      )

    refute system_msg["content"] =~ "PD_SECRET_MEMORY"
    refute system_msg["content"] =~ "WS_SECRET_MEMORY"
  end

  defmodule LessonStoreStub do
    def top_lessons("agent-with-lessons", 5, min_confidence: 0.4) do
      [%{content: "Verify file paths before editing."}]
    end

    def top_lessons("agent-raises", 5, min_confidence: 0.4) do
      raise "db unavailable"
    end

    def top_lessons("agent-bug", 5, min_confidence: 0.4) do
      raise KeyError, key: :missing_field, term: %{}
    end

    def top_lessons("agent-error-tuple", 5, min_confidence: 0.4) do
      {:error, :db_offline}
    end

    def top_lessons(_agent_id, _limit, _opts), do: []
  end

  defmodule SkillIndexFileErrorStub do
    def build(_workspace_path),
      do: raise(File.Error, reason: :eacces, action: "read", path: "/skills")
  end

  defmodule SkillIndexBugStub do
    def build(_workspace_path), do: raise(ArithmeticError, message: "bad arithmetic")
  end

  describe "bootstrap_active?/2" do
    test "returns true when BOOTSTRAP.md exists and identity/soul are absent" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_pa_boot_#{System.unique_integer([:positive])}")

      File.mkdir_p!(AgentPaths.pincer_dir(workspace))
      on_exit(fn -> File.rm_rf!(workspace) end)

      File.write!(AgentPaths.bootstrap_path(workspace), "# Bootstrap ritual")

      assert PromptAssembly.bootstrap_active?(workspace)
    end

    test "returns false when IDENTITY.md and SOUL.md already exist even if BOOTSTRAP.md exists" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_pa_boot_done_#{System.unique_integer([:positive])}")

      File.mkdir_p!(AgentPaths.pincer_dir(workspace))
      on_exit(fn -> File.rm_rf!(workspace) end)

      File.write!(AgentPaths.identity_path(workspace), "# Identity")
      File.write!(AgentPaths.soul_path(workspace), "# Soul")
      File.write!(AgentPaths.bootstrap_path(workspace), "# Bootstrap ritual")

      refute PromptAssembly.bootstrap_active?(workspace)
    end

    test "returns false when BOOTSTRAP.md is absent" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_pa_noboot_#{System.unique_integer([:positive])}")

      File.mkdir_p!(AgentPaths.pincer_dir(workspace))
      on_exit(fn -> File.rm_rf!(workspace) end)

      refute PromptAssembly.bootstrap_active?(workspace)
    end
  end

  describe "build_system_prompt/1" do
    test "reads workspace persona files, omits bootstrap when inactive, and renders self_state and lessons" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_pa_sys_#{System.unique_integer([:positive])}")

      File.mkdir_p!(AgentPaths.pincer_dir(workspace))
      on_exit(fn -> File.rm_rf!(workspace) end)

      File.write!(AgentPaths.identity_path(workspace), "Atlas")
      File.write!(AgentPaths.soul_path(workspace), "Calm and precise")
      File.write!(AgentPaths.user_path(workspace), "Void")
      File.write!(AgentPaths.style_path(workspace), "Direct")
      File.write!(AgentPaths.history_path(workspace), "Prev chat")
      File.write!(AgentPaths.bootstrap_path(workspace), "Should be hidden")

      self_state = %Schema{
        agent_id: "agent-with-lessons",
        wakefulness: "alert",
        mood_valence: 0.4,
        mood_arousal: 0.3,
        focus: "issue-1",
        concerns: [],
        open_questions: [],
        last_reflection_summary: nil
      }

      prompt =
        PromptAssembly.build_system_prompt(
          workspace_path: workspace,
          root_agent_id: "agent-with-lessons",
          self_state: self_state,
          lesson_store: LessonStoreStub
        )

      refute prompt =~ "BOOTSTRAP MODE ACTIVE"
      assert prompt =~ "Atlas"
      assert prompt =~ "Calm and precise"
      assert prompt =~ "Void"
      assert prompt =~ "## COMMUNICATION STYLE:\nDirect"
      assert prompt =~ "## SESSION HISTORY:\nPrev chat"
      assert prompt =~ "## INTERNAL STATE:"
      assert prompt =~ "[Focus] issue-1"
      assert prompt =~ "## LESSONS FROM EXPERIENCE:"
      assert prompt =~ "- Verify file paths before editing."
    end

    test "includes bootstrap block when active and degrades gracefully if lesson store raises" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_pa_boot_sys_#{System.unique_integer([:positive])}")

      File.mkdir_p!(AgentPaths.pincer_dir(workspace))
      on_exit(fn -> File.rm_rf!(workspace) end)

      File.write!(AgentPaths.bootstrap_path(workspace), "Introduce yourself!")

      prompt =
        PromptAssembly.build_system_prompt(
          workspace_path: workspace,
          root_agent_id: "agent-raises",
          self_state: nil,
          lesson_store: LessonStoreStub
        )

      assert prompt =~ "!!! BOOTSTRAP MODE ACTIVE !!!\nIntroduce yourself!"
      refute prompt =~ "## INTERNAL STATE:"
      refute prompt =~ "## LESSONS FROM EXPERIENCE:"
      assert prompt =~ "## CAPABILITIES & TOOLS:"
    end

    test "degrades gracefully with warning on lesson error tuple or skill File.Error, but surfaces unexpected bugs" do
      import ExUnit.CaptureLog

      workspace =
        Path.join(System.tmp_dir!(), "pincer_pa_narrow_#{System.unique_integer([:positive])}")

      File.mkdir_p!(AgentPaths.pincer_dir(workspace))
      on_exit(fn -> File.rm_rf!(workspace) end)

      log =
        capture_log(fn ->
          prompt =
            PromptAssembly.build_system_prompt(
              workspace_path: workspace,
              root_agent_id: "agent-error-tuple",
              self_state: nil,
              lesson_store: LessonStoreStub,
              prompt_index: SkillIndexFileErrorStub
            )

          refute prompt =~ "## LESSONS FROM EXPERIENCE:"
          assert prompt =~ "## CAPABILITIES & TOOLS:"
        end)

      assert log =~ "Failed to load lessons"
      assert log =~ "Failed to build skills index"

      assert_raise KeyError, fn ->
        PromptAssembly.build_system_prompt(
          workspace_path: workspace,
          root_agent_id: "agent-bug",
          self_state: nil,
          lesson_store: LessonStoreStub
        )
      end

      assert_raise ArithmeticError, fn ->
        PromptAssembly.build_system_prompt(
          workspace_path: workspace,
          root_agent_id: "agent-with-lessons",
          self_state: nil,
          lesson_store: LessonStoreStub,
          prompt_index: SkillIndexBugStub
        )
      end
    end
  end

  describe "curated memory bounds" do
    test "prepare bounds an oversized MEMORY.md before injecting it" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_pa_mem_cap_#{System.unique_integer([:positive])}")

      File.mkdir_p!(AgentPaths.pincer_dir(workspace))
      on_exit(fn -> File.rm_rf!(workspace) end)

      lines = for index <- 1..120, do: "HEAD_MEMORY_LINE_#{index} #{String.duplicate("m", 40)}"

      File.write!(
        AgentPaths.memory_path(workspace),
        Enum.join(lines, "\n") <> "\nTAIL_MEMORY_SECRET"
      )

      history = [
        %{"role" => "system", "content" => "System base"},
        %{"role" => "user", "content" => "Oi"}
      ]

      [system_msg | _] =
        PromptAssembly.prepare(history, %{provider: "stub_provider", model: "x"},
          current_time: "2026-03-14 00:00:00Z",
          workspace_path: workspace,
          storage: StorageStub,
          memory_recall: RecallStub,
          llm_client: LLMStub,
          context_strategy: nil
        )

      content = system_msg["content"]

      assert content =~ "HEAD_MEMORY_LINE_1 "
      refute content =~ "HEAD_MEMORY_LINE_120 "
      refute content =~ "TAIL_MEMORY_SECRET"
      assert content =~ "[truncated]"
    end

    test "build_system_prompt bounds an oversized USER.md before injecting it" do
      workspace =
        Path.join(System.tmp_dir!(), "pincer_pa_user_cap_#{System.unique_integer([:positive])}")

      File.mkdir_p!(AgentPaths.pincer_dir(workspace))
      on_exit(fn -> File.rm_rf!(workspace) end)

      lines = for index <- 1..120, do: "HEAD_USER_LINE_#{index} #{String.duplicate("u", 40)}"
      File.write!(AgentPaths.user_path(workspace), Enum.join(lines, "\n") <> "\nTAIL_USER_SECRET")

      prompt =
        PromptAssembly.build_system_prompt(
          workspace_path: workspace,
          root_agent_id: "agent-with-lessons",
          self_state: nil,
          lesson_store: LessonStoreStub
        )

      assert prompt =~ "HEAD_USER_LINE_1 "
      refute prompt =~ "HEAD_USER_LINE_120 "
      refute prompt =~ "TAIL_USER_SECRET"
      assert prompt =~ "[truncated]"
    end
  end
end
