defmodule Pincer.Channels.Shared.Chunking do
  @moduledoc """
  Shared outbound message chunking and incremental stream-buffer flushing helpers
  used across channel adapters.
  """

  @default_sentence_boundary ~r/[.!?](\s|$)/
  @default_stream_max_bytes 500
  @default_search_range 500

  @type strategy :: :lines | :newline_window | :graphemes

  @doc """
  Splits outbound `text` into Unicode-safe chunks of at most `max_len` graphemes.

  ## Strategies

    - `:lines` (default) - preserves line breaks where possible and splits
      overlong single lines by graphemes.
    - `:newline_window` - slices at `max_len` and walks back up to
      `:search_range` characters (default `500`) to break right after the last newline.
    - `:graphemes` - splits directly into fixed-size grapheme chunks.
  """
  @spec split(String.t() | nil, pos_integer(), keyword()) :: [String.t()]
  def split(text, max_len, opts \\ [])

  def split(nil, _max_len, _opts), do: []
  def split("", _max_len, _opts), do: []

  def split(text, max_len, opts)
      when is_binary(text) and is_integer(max_len) and max_len > 0 and is_list(opts) do
    case Keyword.get(opts, :strategy, :lines) do
      :lines ->
        split_by_lines(text, max_len)

      :newline_window ->
        search_range = Keyword.get(opts, :search_range, @default_search_range)
        split_newline_window(text, max_len, search_range)

      :graphemes ->
        split_by_graphemes(text, max_len)
    end
  end

  @doc """
  Returns `true` when an accumulated stream buffer should be flushed to a channel
  without native message editing.
  """
  @spec should_flush_stream?(String.t(), keyword()) :: boolean()
  def should_flush_stream?(buffer, opts \\ []) when is_binary(buffer) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_stream_max_bytes)
    boundary = Keyword.get(opts, :sentence_boundary, @default_sentence_boundary)
    byte_size(buffer) > max_bytes or Regex.match?(boundary, buffer)
  end

  @doc """
  Appends a streaming `token` to `buffer` and returns `{:flush, payload, ""}`
  when flush criteria are met or `{:buffer, new_buffer}` otherwise.
  """
  @spec append_stream_buffer(String.t(), term(), keyword()) ::
          {:flush, String.t(), String.t()} | {:buffer, String.t()}
  def append_stream_buffer(buffer, token, opts \\ []) when is_binary(buffer) and is_list(opts) do
    new_buffer = buffer <> to_string(token)

    if should_flush_stream?(new_buffer, opts) do
      {:flush, new_buffer, ""}
    else
      {:buffer, new_buffer}
    end
  end

  defp split_by_lines(text, max_len) do
    text
    |> String.split("\n", trim: false)
    |> accumulate_lines(max_len, [], [], 0)
  end

  defp accumulate_lines([], _max_len, rev_chunks, [], _current_len) do
    Enum.reverse(rev_chunks)
  end

  defp accumulate_lines([], _max_len, rev_chunks, rev_current_parts, _current_len) do
    Enum.reverse([flush_parts(rev_current_parts) | rev_chunks])
  end

  defp accumulate_lines([line | rest], max_len, rev_chunks, rev_current_parts, current_len) do
    line_with_newline = if rest == [], do: line, else: line <> "\n"
    line_len = String.length(line_with_newline)

    cond do
      line_len > max_len ->
        rev_chunks = flush_into(rev_chunks, rev_current_parts)
        blind_parts = split_by_graphemes(line_with_newline, max_len)
        {rev_chunks, new_current} = push_blind_parts(blind_parts, rev_chunks)
        new_len = last_chunk_len(line_len, max_len)
        accumulate_lines(rest, max_len, rev_chunks, [new_current], new_len)

      current_len + line_len > max_len ->
        rev_chunks = flush_into(rev_chunks, rev_current_parts)
        accumulate_lines(rest, max_len, rev_chunks, [line_with_newline], line_len)

      true ->
        accumulate_lines(
          rest,
          max_len,
          rev_chunks,
          [line_with_newline | rev_current_parts],
          current_len + line_len
        )
    end
  end

  defp flush_into(rev_chunks, []), do: rev_chunks
  defp flush_into(rev_chunks, rev_parts), do: [flush_parts(rev_parts) | rev_chunks]

  defp flush_parts(rev_parts), do: rev_parts |> Enum.reverse() |> IO.iodata_to_binary()

  defp push_blind_parts([last], rev_chunks), do: {rev_chunks, last}

  defp push_blind_parts([part | rest], rev_chunks) do
    push_blind_parts(rest, [part | rev_chunks])
  end

  defp last_chunk_len(total_len, max_len) do
    case rem(total_len, max_len) do
      0 -> max_len
      remainder -> remainder
    end
  end

  defp split_by_graphemes(text, max_len) do
    if String.length(text) <= max_len do
      [text]
    else
      text
      |> String.graphemes()
      |> Enum.chunk_every(max_len)
      |> Enum.map(&IO.iodata_to_binary/1)
    end
  end

  defp split_newline_window(text, max_len, search_range) do
    graphemes = String.graphemes(text)
    total_len = length(graphemes)

    if total_len <= max_len do
      [text]
    else
      do_split_newline_window(graphemes, total_len, max_len, search_range, [])
    end
  end

  defp do_split_newline_window(graphemes, remaining_len, max_len, _search_range, rev_chunks)
       when remaining_len <= max_len do
    Enum.reverse([IO.iodata_to_binary(graphemes) | rev_chunks])
  end

  defp do_split_newline_window(graphemes, remaining_len, max_len, search_range, rev_chunks) do
    min_pos = max(0, max_len - search_range)
    split_at = find_window_split(graphemes, 0, max_len, min_pos, nil) || max_len
    {chunk_graphemes, rest_graphemes} = Enum.split(graphemes, split_at)
    chunk = IO.iodata_to_binary(chunk_graphemes)

    do_split_newline_window(
      rest_graphemes,
      remaining_len - split_at,
      max_len,
      search_range,
      [chunk | rev_chunks]
    )
  end

  defp find_window_split(_graphemes, idx, max_len, _min_pos, last_nl_pos) when idx >= max_len,
    do: last_nl_pos

  defp find_window_split([], _idx, _max_len, _min_pos, last_nl_pos), do: last_nl_pos

  defp find_window_split([g | rest], idx, max_len, min_pos, last_nl_pos) do
    next_nl_pos =
      if idx >= min_pos and (g == "\n" or g == "\r\n") do
        idx + 1
      else
        last_nl_pos
      end

    find_window_split(rest, idx + 1, max_len, min_pos, next_nl_pos)
  end
end
