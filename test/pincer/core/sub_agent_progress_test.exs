defmodule Pincer.Core.SubAgentProgressTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.SubAgentProgress

  test "apply_event accumulates structured state for a running sub-agent" do
    tracker =
      %{}
      |> SubAgentProgress.apply_event(%{agent_id: "a1", kind: :started, goal: "scan repo"})
      |> SubAgentProgress.apply_event(%{agent_id: "a1", kind: :tool, tool: "file_system.search"})
      |> SubAgentProgress.apply_event(%{
        agent_id: "a1",
        kind: :llm_status,
        status: "HTTP 429: retry in 2.0s"
      })

    assert tracker["a1"].goal == "scan repo"
    assert tracker["a1"].started?
    assert tracker["a1"].state == :running
    assert tracker["a1"].last_tool == "file_system.search"
    assert tracker["a1"].last_status == "HTTP 429: retry in 2.0s"
  end

  test "render_dashboard shows running, finished and failed checklist states" do
    tracker =
      %{}
      |> SubAgentProgress.apply_event(%{agent_id: "a1", kind: :started, goal: "scan repo"})
      |> SubAgentProgress.apply_event(%{agent_id: "a1", kind: :tool, tool: "rg"})
      |> SubAgentProgress.apply_event(%{agent_id: "a2", kind: :started, goal: "deploy"})
      |> SubAgentProgress.apply_event(%{agent_id: "a2", kind: :finished, result: "done"})
      |> SubAgentProgress.apply_event(%{agent_id: "a3", kind: :started, goal: "watch logs"})
      |> SubAgentProgress.apply_event(%{agent_id: "a3", kind: :failed, reason: "timeout"})

    dashboard = SubAgentProgress.render_dashboard(tracker)

    assert dashboard =~ "Sub-Agent Checklist"
    assert dashboard =~ "`a1`"
    assert dashboard =~ "Goal: scan repo"
    assert dashboard =~ "☑ Started"
    assert dashboard =~ "☐ Finished"
    assert dashboard =~ "Last tool: `rg`"
    assert dashboard =~ "`a2`"
    assert dashboard =~ "☑ Finished"
    assert dashboard =~ "Result: done"
    assert dashboard =~ "`a3`"
    assert dashboard =~ "☒ Failed: timeout"
  end

  test "emits start notification once per agent" do
    messages = [
      %{agent_id: "a1", content: "Started with goal: scan repo"},
      %{agent_id: "a1", content: "Started with goal: scan repo"}
    ]

    {notifications, tracker, needs_review?} = SubAgentProgress.notifications(messages, %{})

    assert notifications == ["🚀 Sub-Agent a1 started."]
    refute needs_review?
    assert tracker["a1"].started?
  end

  test "emits tool notification only when tool changes" do
    messages = [
      %{agent_id: "a1", content: "Using tool: grep"},
      %{agent_id: "a1", content: "Using tool: grep"},
      %{agent_id: "a1", content: "Using tool: sed"}
    ]

    {notifications, tracker, needs_review?} = SubAgentProgress.notifications(messages, %{})

    assert notifications == [
             "⚙️ Sub-Agent a1 running: grep.",
             "⚙️ Sub-Agent a1 running: sed."
           ]

    refute needs_review?
    assert tracker["a1"].last_tool == "sed"
  end

  test "emits terminal notification once and ignores later tool updates for that agent" do
    messages = [
      %{agent_id: "a1", content: "FINISHED: done"},
      %{agent_id: "a1", content: "Using tool: ignored"}
    ]

    {notifications, tracker, needs_review?} = SubAgentProgress.notifications(messages, %{})

    assert notifications == ["✅ Sub-Agent a1 finished."]
    refute needs_review?
    assert tracker["a1"].terminal?
  end

  test "emits llm runtime status notification and avoids duplicate status" do
    messages = [
      %{agent_id: "a1", content: "LLM_STATUS: HTTP 429: retry in 2.0s (4 retries left)."},
      %{agent_id: "a1", content: "LLM_STATUS: HTTP 429: retry in 2.0s (4 retries left)."},
      %{agent_id: "a1", content: "LLM_STATUS: HTTP 429: retry in 4.0s (3 retries left)."}
    ]

    {notifications, tracker, needs_review?} = SubAgentProgress.notifications(messages, %{})

    assert notifications == [
             "🧠 Sub-Agent a1: HTTP 429: retry in 2.0s (4 retries left).",
             "🧠 Sub-Agent a1: HTTP 429: retry in 4.0s (3 retries left)."
           ]

    refute needs_review?
    assert tracker["a1"].last_status == "HTTP 429: retry in 4.0s (3 retries left)."
  end

  test "marks needs_review when unknown update arrives" do
    messages = [
      %{agent_id: "a1", content: "random intermediate update"}
    ]

    {notifications, _tracker, needs_review?} = SubAgentProgress.notifications(messages, %{})

    assert notifications == []
    assert needs_review?
  end
end
