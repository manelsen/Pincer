defmodule Pincer.Utils.TextTest do
  use ExUnit.Case, async: true

  alias Pincer.Utils.Text

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

  test "extract_xml_tool_calls does not break closed thinking blocks" do
    input = "<thinking>\nsegredo interno\n</thinking>\n\nOla! Como posso ajudar?"

    assert {cleaned, []} = Text.extract_xml_tool_calls(input)
    assert Text.strip_reasoning(cleaned) == "Ola! Como posso ajudar?"
  end
end
