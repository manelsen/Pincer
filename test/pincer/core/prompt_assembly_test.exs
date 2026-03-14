defmodule Pincer.Core.PromptAssemblyTest do
  use ExUnit.Case, async: true

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
        long_term_memory: "Manel prefere respostas objetivas.",
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
    assert content =~ "Manel prefere respostas objetivas."
    assert content =~ "RECENT LEARNINGS & ERRORS"
    assert content =~ "Use web_fetch for plain URL reading"
    assert content =~ "browser pool unavailable"
    assert content =~ "MEMORY RECALL"
    assert content =~ "previous preference"
  end
end
