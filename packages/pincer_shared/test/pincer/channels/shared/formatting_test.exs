defmodule Pincer.Channels.Shared.FormattingTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Shared.Formatting

  describe "reasoning helpers" do
    test "strip_reasoning/1 strips hidden blocks while preserving nil and non-binaries" do
      assert is_nil(Formatting.strip_reasoning(nil))
      assert Formatting.strip_reasoning(42) == 42

      assert Formatting.strip_reasoning("<thinking>internal</thinking>\n\nVisible") == "Visible"
      assert Formatting.strip_reasoning("<thought>secret</thought>Answer") == "Answer"
      assert Formatting.strip_reasoning("think> planning...\n\nHello!") == "Hello!"
    end

    test "format_reasoning/2 respects :skip_reasoning_strip" do
      raw = "<thinking>sec</thinking>\n\nAnswer"

      assert Formatting.format_reasoning(raw) == "Answer"

      assert Formatting.format_reasoning(raw, skip_reasoning_strip: true) ==
               "<b>💭 Reasoning</b>\n<i>&lt;thinking&gt;sec&lt;/thinking&gt;</i>\n\nAnswer"
    end
  end

  describe "HTML fencing and Markdown orchestration" do
    test "fence_html/1 and unfence_html/2 protect pre, code, and safe inline tags" do
      input = "<b>HTML</b> and `inline` and <pre><code>raw &lt;x&gt;</code></pre>"

      {fenced, map} = Formatting.fence_html(input)

      refute fenced =~ "<b>"
      refute fenced =~ "<pre>"
      assert Formatting.unfence_html(fenced, map) == input
    end

    test "wrap_file_references/1 wraps known filenames without wrapping unrelated words" do
      assert Formatting.wrap_file_references("See README.md and main.go today.") ==
               "See <code>README.md</code> and <code>main.go</code> today."
    end

    test "markdown_to_html/2 fences, applies custom renderer, unfences, wraps file refs, and trims" do
      input = "<b>keep</b> **bold** README.md\r\n"

      rendered =
        Formatting.markdown_to_html(input,
          render_markdown: fn fenced ->
            String.replace(fenced, "**bold**", "<b>bold</b>")
          end
        )

      assert rendered == "<b>keep</b> <b>bold</b> <code>README.md</code>"
    end

    test "html_to_plain_text/1 decodes entities, converts br tags, and strips tags" do
      assert is_nil(Formatting.html_to_plain_text(nil))

      html = "<b>A &amp; B</b><br/><i>C</i> &quot;quoted&quot;"
      assert Formatting.html_to_plain_text(html) == "A & B\nC \"quoted\""
    end
  end

  describe "channel-specific markdown formatters" do
    test "markdown_to_discord/1 strips reasoning and trims" do
      assert Formatting.markdown_to_discord(nil) == ""

      assert Formatting.markdown_to_discord("<thought>hide</thought>  **Hello**  ") ==
               "**Hello**"
    end

    test "markdown_to_mrkdwn/1 converts bold, underline/italic, and links" do
      assert Formatting.markdown_to_mrkdwn(nil) == ""

      assert Formatting.markdown_to_mrkdwn("**bold** __ital__ [Pincer](https://pincer.ai)") ==
               "*bold* _ital_ <https://pincer.ai|Pincer>"
    end
  end
end
