defmodule Pincer.Channels.Shared.ChunkingTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Shared.Chunking

  describe "split/3" do
    test "returns empty list for nil or empty string" do
      assert Chunking.split("", 100) == []
      assert Chunking.split(nil, 100) == []
      assert Chunking.split("", 100, strategy: :newline_window) == []
      assert Chunking.split("", 100, strategy: :graphemes) == []
    end

    test "line strategy preserves lines, splits overlong lines by graphemes, and round-trips" do
      text =
        "line 1\n" <>
          "line 2\n" <>
          String.duplicate("🌟", 25) <> "\nfinal line"

      chunks = Chunking.split(text, 12, strategy: :lines)

      assert length(chunks) >= 4
      assert Enum.all?(chunks, &(String.length(&1) <= 12))
      assert Enum.join(chunks, "") == text
    end

    test "newline_window strategy splits on last newline within range and is Unicode-safe" do
      prefix = String.duplicate("🌟", 1800)
      mid = "\nTarget\n"
      suffix = String.duplicate("🚀", 500)
      text = prefix <> mid <> suffix

      chunks = Chunking.split(text, 1900, strategy: :newline_window, search_range: 500)

      assert length(chunks) >= 2
      first_chunk = Enum.at(chunks, 0)
      assert String.contains?(first_chunk, "Target")
      assert String.ends_with?(first_chunk, "\n")
      assert Enum.all?(chunks, &(String.length(&1) <= 1900))
      assert Enum.join(chunks, "") == text
    end

    test "newline_window strategy avoids corruption on ZWJ emojis without newlines" do
      text = String.duplicate("👨‍👩‍👧‍👦", 120)

      chunks = Chunking.split(text, 50, strategy: :newline_window)

      assert Enum.join(chunks, "") == text
      assert Enum.all?(chunks, &(String.length(&1) <= 50))
    end

    test "graphemes strategy splits into fixed-size grapheme chunks" do
      text = String.duplicate("á", 10) <> String.duplicate("🚀", 5)

      chunks = Chunking.split(text, 6, strategy: :graphemes)

      assert length(chunks) == 3
      assert Enum.all?(chunks, &(String.length(&1) <= 6))
      assert Enum.join(chunks, "") == text
    end

    test "lines strategy handles multi-chunk and overlong inputs cleanly in O(n)" do
      lines =
        for i <- 1..15_000 do
          if rem(i, 500) == 0, do: String.duplicate("x", 45), else: "line #{i}"
        end

      text = Enum.join(lines, "\n")

      {elapsed_us, chunks} =
        :timer.tc(fn ->
          Chunking.split(text, 20, strategy: :lines)
        end)

      assert length(chunks) > 5_000
      assert Enum.all?(chunks, &(String.length(&1) <= 20))
      assert Enum.join(chunks, "") == text
      assert elapsed_us < 1_000_000
    end

    test "newline_window strategy handles multi-chunk inputs cleanly in O(n)" do
      block = String.duplicate("abcdefghij\n", 10)
      text = String.duplicate(block, 600)

      {elapsed_us, chunks} =
        :timer.tc(fn ->
          Chunking.split(text, 50, strategy: :newline_window, search_range: 20)
        end)

      assert length(chunks) > 1_200
      assert Enum.all?(chunks, &(String.length(&1) <= 50))
      assert Enum.join(chunks, "") == text
      assert elapsed_us < 500_000
    end

    test "newline_window strategy respects search_range: 0 and CRLF boundaries" do
      text = "aaa\r\nbbb\r\nccc"
      chunks = Chunking.split(text, 5, strategy: :newline_window, search_range: 5)
      assert Enum.join(chunks, "") == text
      assert Enum.all?(chunks, &(String.length(&1) <= 5))

      no_range_chunks = Chunking.split("ab\ncdef", 4, strategy: :newline_window, search_range: 0)
      assert no_range_chunks == ["ab\nc", "def"]
    end
  end

  describe "streaming buffer helpers" do
    test "should_flush_stream?/2 detects sentence boundaries or byte thresholds" do
      assert Chunking.should_flush_stream?("Hello world. ")
      assert Chunking.should_flush_stream?("Done!")
      assert Chunking.should_flush_stream?("Really?")
      refute Chunking.should_flush_stream?("Hello world")
      assert Chunking.should_flush_stream?(String.duplicate("a", 501), max_bytes: 500)
      refute Chunking.should_flush_stream?(String.duplicate("a", 500), max_bytes: 500)
    end

    test "append_stream_buffer/3 accumulates until boundary or size limit" do
      assert {:buffer, "Hello "} = Chunking.append_stream_buffer("", "Hello ", max_bytes: 500)

      assert {:flush, "Hello world. ", ""} =
               Chunking.append_stream_buffer("Hello ", "world. ", max_bytes: 500)

      long_chunk = String.duplicate("a", 11)

      assert {:flush, ^long_chunk, ""} =
               Chunking.append_stream_buffer("", long_chunk, max_bytes: 10)
    end
  end
end
