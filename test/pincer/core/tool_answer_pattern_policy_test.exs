defmodule Pincer.Core.ToolAnswerPatternPolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ToolAnswerPatternPolicy

  test "adds git-specific guidance when git_inspect was used" do
    text = ToolAnswerPatternPolicy.build([%{"name" => "git_inspect", "content" => "## main"}])

    assert text =~ "For Git inspection tools"
    assert text =~ "status: branch"
    assert text =~ "Do not say the Git command failed"
  end

  test "adds github-specific guidance for MCP github tool names" do
    text =
      ToolAnswerPatternPolicy.build([%{"name" => "get_issue", "content" => "{\"title\":\"x\"}"}])

    assert text =~ "For GitHub tools"
    assert text =~ "get_issue/get_pr"
    assert text =~ "instead of dumping raw JSON"
  end

  test "returns empty text for unrelated tools" do
    assert ToolAnswerPatternPolicy.build([%{"name" => "web_fetch", "content" => "ok"}]) == ""
  end

  test "grounding_message builds base user grounding prompt and appends tool guidance" do
    plain = ToolAnswerPatternPolicy.grounding_message([%{"name" => "web_fetch"}])
    assert plain["role"] == "user"
    assert plain["content"] =~ "Ground yourself strictly in the tool outputs above"
    refute plain["content"] =~ "For Git inspection tools"

    git = ToolAnswerPatternPolicy.grounding_message([%{"name" => "git_inspect"}])
    assert git["role"] == "user"
    assert git["content"] =~ "Ground yourself strictly in the tool outputs above"
    assert git["content"] =~ "For Git inspection tools"
  end
end
