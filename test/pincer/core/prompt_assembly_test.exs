defmodule Pincer.Core.PromptAssemblyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Introspection.Schema
  alias Pincer.Core.PromptAssembly

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
        long_term_memory: "User prefere respostas objetivas.",
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
    assert content =~ "User prefere respostas objetivas."
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

    def top_lessons(_agent_id, _limit, _opts), do: []
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
  end
end
