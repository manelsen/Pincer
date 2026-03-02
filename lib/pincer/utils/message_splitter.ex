defmodule Pincer.Utils.MessageSplitter do
  @moduledoc """
  Utility for splitting long text messages into safe chunks.
  Prioritizes preserving formatting (paragraphs, words) over exact length.
  """

  @default_limit 4000 # Telegram limit is 4096, keeping safety margin for HTML tags

  @doc """
  Splits text into chunks of at most `limit` characters.
  
  Strategy:
  1. Split by newlines first (paragraphs/lines).
  2. Accumulate lines until limit is reached.
  3. If a single line exceeds limit, split by words.
  4. If a single word exceeds limit, hard split.
  """
  def split(text, limit \\ @default_limit) do
    # First pass: preserve paragraphs/lines
    lines = String.split(text, ~r/(?:\r\n|\n)/)
    
    Enum.reduce(lines, [], fn line, acc ->
      process_line(line, acc, limit)
    end)
    |> Enum.reverse()
  end

  defp process_line(line, [], limit) do
    # First line matches logic of "add to empty chunk"
    # But wait, line might be huge.
    if String.length(line) > limit do
      split_huge_line(line, limit) |> Enum.reverse() # Reverse because accumulator expects reversed list
    else
      [line]
    end
  end

  defp process_line(line, [current_chunk | rest], limit) do
    separator = "\n"
    current_len = String.length(current_chunk)
    line_len = String.length(line)
    sep_len = String.length(separator)

    cond do
      # Case 1: Line fits in current chunk
      current_len + sep_len + line_len <= limit ->
        [current_chunk <> separator <> line | rest]

      # Case 2: Line fits in a NEW chunk
      line_len <= limit ->
        [line, current_chunk | rest]

      # Case 3: Line is huge (larger than limit on its own)
      true ->
        # Finalize current chunk, split the huge line, push all parts
        chunks = split_huge_line(line, limit)
        # Result needs to be [last_part, ..., first_part, current_chunk | rest]
        # split_huge_line returns [part1, part2, ...].
        # We need to reverse it to prepend to accumulator.
        Enum.reverse(chunks) ++ [current_chunk | rest]
    end
  end

  # Splits a string that is known to be larger than limit
  defp split_huge_line(text, limit) do
    # Try splitting by spaces first to preserve words
    words = String.split(text, " ")
    
    # If it was just one massive word (no spaces), fall back to hard chunking
    if length(words) == 1 do
      text
      |> String.codepoints()
      |> Enum.chunk_every(limit)
      |> Enum.map(&Enum.join/1)
    else
      # Re-accumulate words into chunks
      Enum.reduce(words, [], fn word, acc ->
        append_word(word, acc, limit)
      end)
      |> Enum.reverse()
    end
  end

  defp append_word(word, [], limit) do
    if String.length(word) > limit do
      # Word itself is huge (e.g. base64 string), hard split it
      split_huge_line(word, limit) |> Enum.reverse()
    else
      [word]
    end
  end

  defp append_word(word, [current | rest], limit) do
    if String.length(current) + 1 + String.length(word) <= limit do
      [current <> " " <> word | rest]
    else
      [word, current | rest]
    end
  end
end
