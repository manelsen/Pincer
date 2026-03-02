defmodule Pincer.Channels.Discord.UnicodeTest do
  use ExUnit.Case, async: true
  alias Pincer.Channels.Discord

  describe "split_into_chunks/2 Unicode safety" do
    test "correctly splits text with multi-byte characters without corruption" do
      # Each emoji is typically 4 bytes. 
      # "🌟" (U+1F31F) is 4 bytes.
      # If we split by byte offset but slice by char offset, we might skip or corrupt text.
      
      # Create a string with emojis and a newline near the 1900 CHAR limit.
      # We want to ensure 'do_split' finds the newline correctly using char offsets.
      
      prefix = String.duplicate("🌟", 1800) # 1800 chars
      mid = "\nTarget\n"
      suffix = String.duplicate("🚀", 500)
      
      text = prefix <> mid <> suffix
      
      chunks = Discord.split_into_chunks(text, 1900)
      
      # The first chunk should end at the last newline within 1900 CHARS.
      # Prefix (1800) + "\nTarget" (7) = 1807 chars.
      # The last newline in first 1900 chars is after "Target".
      
      assert length(chunks) >= 2
      first_chunk = Enum.at(chunks, 0)
      
      # Check if "Target" is in the first chunk
      assert String.contains?(first_chunk, "Target")
      # Check that the split actually happened at or after a newline
      assert String.ends_with?(first_chunk, "\n")
      
      # Reassemble and compare
      assert Enum.join(chunks, "") == text
    end

    test "avoids infinite loop or corruption when no newline is found" do
      # Case where a extremely long string with no newlines and many emojis is split.
      text = String.duplicate("👨‍👩‍👧‍👦", 1000) # Complex emoji (multiple codepoints)
      
      chunks = Discord.split_into_chunks(text, 100)
      assert Enum.join(chunks, "") == text
      assert Enum.all?(chunks, fn c -> String.length(c) <= 100 end)
    end
  end
end
