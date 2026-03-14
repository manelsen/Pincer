defmodule Pincer.Core.ToolResultSummaryTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ToolResultSummary

  test "summarizes GitHub issue JSON payloads" do
    assert ToolResultSummary.summarize(%{
             "name" => "get_issue",
             "content" =>
               ~s({"number":168,"title":"OpenClaw ecosystem daily report","state":"open","html_url":"https://github.com/duanyytop/agents-radar/issues/168"})
           }) ==
             "Issue #168: OpenClaw ecosystem daily report\nState: open\nhttps://github.com/duanyytop/agents-radar/issues/168"
  end

  test "summarizes git inspect output with first meaningful lines" do
    assert ToolResultSummary.summarize(%{
             "name" => "git_inspect",
             "content" => "## feature/demo\n M notes.txt\n?? scratch.txt\n"
           }) ==
             "## feature/demo\n M notes.txt\n?? scratch.txt"
  end

  test "returns nil when specialized summary does not apply" do
    assert ToolResultSummary.summarize(%{"name" => "web_fetch", "content" => "plain text"}) == nil
  end

  test "summarizes GitHub issue collections from JSON arrays" do
    assert ToolResultSummary.summarize(%{
             "name" => "list_issues",
             "content" =>
               ~s([{"number":7,"title":"Bug in scheduler","state":"open","html_url":"https://github.com/user/pincer/issues/7"},{"number":8,"title":"Crash on startup","state":"closed","html_url":"https://github.com/user/pincer/issues/8"}])
           }) ==
             "Issues:\n- #7 Bug in scheduler (open) https://github.com/user/pincer/issues/7\n- #8 Crash on startup (closed) https://github.com/user/pincer/issues/8"
  end

  test "summarizes commit collections from JSON arrays" do
    assert ToolResultSummary.summarize(%{
             "name" => "list_commits",
             "content" =>
               ~s([{"sha":"abc1234","commit":{"message":"Fix bug\\n\\nbody","author":{"name":"alice","date":"2026-03-11T00:00:00Z"}}}])
           }) ==
             "Commits:\n- abc1234 Fix bug (alice, 2026-03-11T00:00:00Z)"
  end
end
