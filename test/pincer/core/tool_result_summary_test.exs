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
end
