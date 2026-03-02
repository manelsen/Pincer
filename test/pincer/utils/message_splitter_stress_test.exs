defmodule Pincer.Utils.MessageSplitterStressTest do
  use ExUnit.Case
  alias Pincer.Utils.MessageSplitter

  @moduledoc """
  Stress tests for the MessageSplitter to ensure it handles structured content
  (HTML/Markdown) correctly by respecting line boundaries.
  """

  describe "split/2 with structured content" do
    test "handles 20 Markdown messages, preserving line boundaries" do
      # 1. Generate 20 Markdown messages
      messages = for i <- 1..20 do
        "### Message #{i}\n* This is a list item for message #{i}.\n* **Bold info** and `code`."
      end
      
      # Join them with double newlines (paragraphs)
      full_text = Enum.join(messages, "\n\n")
      
      # 2. Set a limit that fits roughly 2.5 messages (approx 200 chars).
      # This forces the splitter to decide where to cut. 
      limit = 200
      
      chunks = MessageSplitter.split(full_text, limit)

      # Assertions
      # A. Constraint Check
      assert Enum.all?(chunks, fn c -> String.length(c) <= limit end), 
             "A chunk exceeded the limit of #{limit} characters."

      # B. Integrity Check (Reassembly)
      # The splitter splits by \n or \r\n. Rejoining with \n should roughly reconstruct the text.
      # Note: Original split regex captures delimiters? No, we fixed it to non-capturing.
      # So `String.split` consumes the delimiter. 
      # `process_line` re-adds `\n` when joining accumulated lines.
      assert Enum.join(chunks, "\n") == full_text

      # C. formatting preservation check
      Enum.each(chunks, fn chunk ->
        # Should start with header or list item, or be a clean continuation
        assert String.match?(chunk, ~r/^(\#\#\#|\*)/), 
               "Chunk started with unexpected character: #{String.slice(chunk, 0, 10)}..."
      end)
    end

    test "handles 20 HTML messages, preserving tags within lines" do
      # 1. Generate 20 HTML blocks
      messages = for i <- 1..20 do
        "<div id='msg-#{i}'><p>This is <b>HTML message #{i}</b>.</p><code>System.out.println(#{i})</code></div>"
      end
      
      full_text = Enum.join(messages, "\n")
      
      # Limit fits approx 3 messages
      limit = 300
      
      chunks = MessageSplitter.split(full_text, limit)

      # Assertions
      assert Enum.all?(chunks, fn c -> String.length(c) <= limit end)
      assert Enum.join(chunks, "\n") == full_text

      # Check that we didn't split inside a tag (e.g. <div...>) because lines are atomic and < limit
      Enum.each(chunks, fn chunk ->
        opens = length(Regex.scan(~r/<div/, chunk))
        closes = length(Regex.scan(~r/<\/div>/, chunk))
        assert opens == closes, "HTML tag imbalance detected in chunk: \n#{chunk}"
      end)
    end

    test "handles mixed long content forcing word splits" do
      long_line = String.duplicate("word ", 50) # 250 chars
      
      messages = for i <- 1..20 do
        "Header #{i}\n#{long_line}\nFooter #{i}"
      end
      
      full_text = Enum.join(messages, "\n")
      
      limit = 100
      
      chunks = MessageSplitter.split(full_text, limit)
      
      assert Enum.all?(chunks, fn c -> String.length(c) <= limit end)
      
      assert String.contains?(Enum.join(chunks, " "), "Header 1")
      assert String.contains?(Enum.join(chunks, " "), "Footer 20")
    end
  end
end
