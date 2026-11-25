defmodule Pincer.Channels.Shared.TextTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Shared.Text

  test "strips reasoning while preserving the visible answer" do
    assert Text.strip_reasoning("<thinking>private</thinking>\n\nVisible") == "Visible"
    assert Text.strip_reasoning("<thought>incomplete") == ""
  end

  test "formats reasoning with escaped HTML while preserving the visible answer" do
    formatted = Text.format_reasoning_html("<thought>a & b</thought> Visible")

    assert formatted =~ "<b>💭 Reasoning</b>"
    assert formatted =~ "a &amp; b"
    assert String.ends_with?(formatted, " Visible")
  end

  test "passes through nil and non-string payloads" do
    for payload <- [nil, %{status: :pending}] do
      assert Text.strip_reasoning(payload) == payload
      assert Text.format_reasoning_html(payload) == payload
    end
  end
end
