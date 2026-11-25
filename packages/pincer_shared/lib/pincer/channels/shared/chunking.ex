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
    lines = String.split(text, "\n", trim: false)
    last_index = length(lines) - 1

    {chunks, current_chunk} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], ""}, fn {line, idx}, {acc, current} ->
        line_with_newline = if idx < last_index, do: line <> "\n", else: line

        cond do
          String.length(line_with_newline) > max_len ->
            acc = if current == "", do: acc, else: acc ++ [current]
            blind_parts = split_by_graphemes(line_with_newline, max_len)
            {new_current, rest} = List.pop_at(blind_parts, -1)
            {acc ++ rest, new_current}

          String.length(current) + String.length(line_with_newline) > max_len ->
            {acc ++ [current], line_with_newline}

          true ->
            {acc, current <> line_with_newline}
        end
      end)

    if current_chunk == "", do: chunks, else: chunks ++ [current_chunk]
  end

  defp split_by_graphemes(text, max_len) do
    if String.length(text) <= max_len do
      [text]
    else
      text
      |> String.graphemes()
      |> Enum.chunk_every(max_len)
      |> Enum.map(&Enum.join/1)
    end
  end

  defp split_newline_window(text, max_len, search_range) do
    if String.length(text) <= max_len do
      [text]
    else
      chunk = String.slice(text, 0, max_len)
      split_at = find_last_newline_within(chunk, search_range) || max_len

      [
        String.slice(text, 0, split_at)
        | split_newline_window(String.slice(text, split_at..-1//1), max_len, search_range)
      ]
    end
  end

  defp find_last_newline_within(text, search_range) do
    len = String.length(text)
    start_pos = max(0, len - search_range)
    tail = String.slice(text, start_pos..-1//1)

    case String.split(tail, "\n") do
      [_] ->
        nil

      parts ->
        last_part_len = parts |> List.last() |> String.length()
        len - last_part_len
    end
  end
end
