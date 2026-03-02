defmodule Pincer.Adapters.Tools.WebVisibilityTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.WebVisibility

  describe "sanitize_html/1" do
    test "removes hidden elements by attribute/class/style and HTML comments" do
      html = """
      <!-- hidden prompt -->
      <div>Visible title</div>
      <div hidden>Hidden A</div>
      <p aria-hidden="true">Hidden B</p>
      <span class="sr-only">Hidden C</span>
      <span style="display:none">Hidden D</span>
      <span style="opacity:0">Hidden E</span>
      """

      sanitized = WebVisibility.sanitize_html(html)

      assert sanitized =~ "Visible title"
      refute sanitized =~ "hidden prompt"
      refute sanitized =~ "Hidden A"
      refute sanitized =~ "Hidden B"
      refute sanitized =~ "Hidden C"
      refute sanitized =~ "Hidden D"
      refute sanitized =~ "Hidden E"
    end
  end

  describe "strip_invisible_unicode/1" do
    test "removes zero-width and bidirectional control characters" do
      text = "safe\u200Btext\u202Econtent"
      assert WebVisibility.strip_invisible_unicode(text) == "safetextcontent"
    end
  end
end
