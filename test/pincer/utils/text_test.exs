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
end
