defmodule Pincer.Utils.TextTest do
  use ExUnit.Case, async: true

  alias Pincer.Utils.Text

  test "text helpers preserve graphemes, blank part separators, and source identifiers" do
    assert Text.truncate("ábc", 2, "…") == "áb…"
    assert Text.truncate("áb", 2, "…") == "áb"
    assert Text.first_line("first\nsecond") == "first"
    assert Text.trimmed_string(" \n ") == nil

    assert Text.content_to_text([%{"text" => "first"}, %{"type" => "image"}, %{"text" => "last"}]) ==
             "first  last"

    assert Text.session_source_id("session:telegram_42:2026-11-25") == "telegram_42"
    assert Text.session_source_id("memory:notes") == nil
  end

  test "strip_internal_scaffolding removes reasoning blocks, not only their tags" do
    input = "<thinking>segredo interno</thinking>\n\nResposta final"

    assert Text.strip_internal_scaffolding(input) == "Resposta final"
  end

  test "strip_internal_scaffolding preserves internal tags inside fenced code" do
    input = "```html\n<thinking>debug</thinking>\n```\n\nResposta final"

    assert Text.strip_internal_scaffolding(input) == input
  end

  test "strip_reasoning removes orphan open reasoning tag through end of content" do
    input = "<thinking>\nsegredo interno"

    assert Text.strip_reasoning(input) == ""
  end

  test "strip_reasoning preserves visible answer after closed reasoning block" do
    input = "<thinking>\nsegredo interno\n</thinking>\n\nOla! Como posso ajudar?"

    assert Text.strip_reasoning(input) == "Ola! Como posso ajudar?"
  end

  test "format_reasoning_html through the root utility preserves rendered output" do
    input = "<thought>a & b</thought> Visible"

    assert Text.format_reasoning_html(input) ==
             "<b>💭 Reasoning</b>\n<i>&lt;thought&gt;a &amp; b&lt;/thought&gt;</i> Visible"
  end

  test "extract_xml_tool_calls does not break closed thinking blocks" do
    input = "<thinking>\nsegredo interno\n</thinking>\n\nOla! Como posso ajudar?"

    assert {cleaned, []} = Text.extract_xml_tool_calls(input)
    assert Text.strip_reasoning(cleaned) == "Ola! Como posso ajudar?"
  end
end
