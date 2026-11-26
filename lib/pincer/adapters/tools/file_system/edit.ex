defmodule Pincer.Adapters.Tools.FileSystem.Edit do
  @moduledoc """
  File reading, writing, appending, patching, and hashline-anchored editing for `FileSystem`.

  Encapsulates all content-level file operations (`read`, `write`, `append`,
  `patch`, and `anchored_edit`) along with hashline digest generation and validation.
  """

  alias Pincer.Adapters.Tools.Args
  alias Pincer.Adapters.Tools.FileSystem

  @max_file_size Application.compile_env(:pincer, :fs_max_file_size, 52_428_800)
  @hashline_dict "ZPMQVRWSNKTXJBYH" |> String.graphemes() |> List.to_tuple()
  @line_ref_regex ~r/^(\d+)#([A-Z]{5})$/

  @doc "Reads a regular file with optional line slicing and hashline formatting."
  @spec read(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(path, args, _workspace_root) do
    if invalid_read_range?(args) do
      {:error, "Cannot combine 'tail_lines' with 'from_line' or 'line_count'."}
    else
      do_read(path, args)
    end
  end

  @doc "Writes string content to a file, creating parent directories if needed."
  @spec write(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def write(path, args, workspace_root) do
    write_or_append(path, args, workspace_root,
      write_opts: [],
      action_label: "Write",
      dir_error: "Cannot write to a directory.",
      verb: "Wrote",
      error_verb: "writing"
    )
  end

  @doc "Appends string content to a file, creating parent directories if needed."
  @spec append(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def append(path, args, workspace_root) do
    write_or_append(path, args, workspace_root,
      write_opts: [:append],
      action_label: "Append",
      dir_error: "Cannot append to a directory.",
      verb: "Appended",
      error_verb: "appending"
    )
  end

  @doc "Applies exact literal text replacement (`old_text` -> `new_text`) to a UTF-8 file."
  @spec patch(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def patch(path, args, workspace_root) do
    with {:ok, old_text} <- FileSystem.fetch_required_string(args, "old_text"),
         {:ok, new_text} <- FileSystem.fetch_string(args, "new_text"),
         {:ok, content} <- read_regular_file(path),
         {:ok, updated, replacements} <- patch_content(content, old_text, new_text, args) do
      case File.write(path, updated) do
        :ok ->
          {:ok,
           "Patched #{replacements} occurrence(s) in '#{FileSystem.relative_to_workspace(path, workspace_root)}'."}

        {:error, reason} ->
          {:error, "Error writing patched file: #{inspect(reason)}"}
      end
    end
  end

  @doc "Applies line-hash anchored edits (`replace`, `insert_after`, `insert_before`) to a UTF-8 file."
  @spec anchored_edit(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def anchored_edit(path, args, workspace_root) do
    with {:ok, edits} <- normalize_anchored_edits(args),
         {:ok, content} <- read_regular_file(path),
         {:ok, updated_content, edit_count} <- apply_anchored_edits(content, edits),
         :ok <- write_updated_content(path, updated_content) do
      {:ok,
       "Applied #{edit_count} anchored edit(s) to '#{FileSystem.relative_to_workspace(path, workspace_root)}'."}
    end
  end

  defp write_or_append(path, args, workspace_root, cfg) do
    content = Args.get(args, "content")

    if is_binary(content) do
      case File.stat(path) do
        {:ok, %{type: :directory}} ->
          {:error, cfg[:dir_error]}

        _ ->
          path
          |> Path.dirname()
          |> File.mkdir_p()

          case File.write(path, content, cfg[:write_opts]) do
            :ok ->
              rel = FileSystem.relative_to_workspace(path, workspace_root)
              {:ok, "#{cfg[:verb]} #{byte_size(content)} bytes to '#{rel}'."}

            {:error, reason} ->
              {:error, "Error #{cfg[:error_verb]} file: #{inspect(reason)}"}
          end
      end
    else
      {:error, "#{cfg[:action_label]} action requires string 'content'."}
    end
  end

  defp do_read(path, args) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > @max_file_size ->
        {:error, "File too large: #{size} bytes (limit: #{@max_file_size})"}

      {:ok, %{type: :regular}} ->
        case File.read(path) do
          {:ok, content} ->
            content
            |> slice_read_content(args)
            |> render_read_output(args, content)

          {:error, reason} ->
            {:error, "Error reading: #{inspect(reason)}"}
        end

      {:ok, %{type: type}} ->
        {:error, "Cannot read non-file type: #{type}"}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp render_read_output(content, args, original_content) do
    if Args.get(args, "hashline") == true do
      {:ok, format_hashlined_content(content, args, original_content)}
    else
      {:ok, content}
    end
  end

  defp slice_read_content(content, args) do
    from_line = normalize_from_line(Args.get(args, "from_line"))
    line_count = normalize_line_count(Args.get(args, "line_count"))
    tail_lines = normalize_line_count(Args.get(args, "tail_lines"))

    cond do
      not is_nil(tail_lines) ->
        content
        |> String.split("\n", trim: false)
        |> take_tail_slice(tail_lines)
        |> Enum.join("\n")
        |> restore_trailing_newline(content)

      from_line == 1 and is_nil(line_count) ->
        content

      true ->
        content
        |> String.split("\n", trim: false)
        |> take_line_slice(from_line, line_count)
        |> Enum.join("\n")
        |> restore_trailing_newline(content)
    end
  end

  defp format_hashlined_content(content, args, original_content) do
    {lines, trailing_newline?} = split_content_lines(content)
    start_line = hashline_start_line(args, original_content, lines)

    rendered =
      lines
      |> Enum.with_index(start_line)
      |> Enum.map_join("\n", fn {line, line_number} ->
        "#{line_number}##{compute_line_hash(line_number, line)}|#{line}"
      end)

    if rendered != "" and trailing_newline?, do: rendered <> "\n", else: rendered
  end

  defp invalid_read_range?(args) do
    Args.get(args, "tail_lines") != nil and
      (Args.get(args, "from_line") != nil or Args.get(args, "line_count") != nil)
  end

  defp normalize_from_line(value) when is_integer(value) and value > 0, do: value
  defp normalize_from_line(_value), do: 1

  defp normalize_line_count(value) when is_integer(value) and value > 0, do: value
  defp normalize_line_count(_value), do: nil

  defp take_line_slice(lines, from_line, nil), do: Enum.drop(lines, from_line - 1)

  defp take_line_slice(lines, from_line, line_count),
    do: lines |> Enum.drop(from_line - 1) |> Enum.take(line_count)

  defp take_tail_slice(lines, tail_lines) do
    lines
    |> drop_trailing_empty_line()
    |> Enum.take(-tail_lines)
  end

  defp drop_trailing_empty_line([]), do: []

  defp drop_trailing_empty_line(lines) do
    if List.last(lines) == "" do
      Enum.drop(lines, -1)
    else
      lines
    end
  end

  defp restore_trailing_newline(result, original) do
    if result != "" and String.ends_with?(original, "\n"), do: result <> "\n", else: result
  end

  defp split_content_lines(content) do
    trailing_newline? = String.ends_with?(content, "\n")

    lines =
      content
      |> String.split("\n", trim: false)
      |> drop_trailing_empty_line()

    {lines, trailing_newline?}
  end

  defp hashline_start_line(args, original_content, rendered_lines) do
    from_line = Args.get(args, "from_line")
    tail_lines = Args.get(args, "tail_lines")

    cond do
      is_integer(from_line) and from_line > 0 ->
        from_line

      is_integer(tail_lines) and tail_lines > 0 ->
        {all_lines, _} = split_content_lines(original_content)
        max(length(all_lines) - length(rendered_lines) + 1, 1)

      true ->
        1
    end
  end

  defp read_regular_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > @max_file_size ->
        {:error, "File too large: #{size} bytes (limit: #{@max_file_size})"}

      {:ok, %{type: :regular}} ->
        case File.read(path) do
          {:ok, content} ->
            if String.valid?(content) do
              {:ok, content}
            else
              {:error, "Patch action only supports UTF-8 text files."}
            end

          {:error, reason} ->
            {:error, "Error reading file: #{inspect(reason)}"}
        end

      {:ok, %{type: type}} ->
        {:error, "Cannot patch non-file type: #{type}"}

      {:error, reason} ->
        {:error, "File not found or inaccessible: #{inspect(reason)}"}
    end
  end

  defp patch_content(_content, "", _new_text, _args), do: {:error, "'old_text' cannot be empty."}

  defp patch_content(content, old_text, new_text, args) do
    occurrences = :binary.matches(content, old_text) |> length()
    replace_all? = Args.get(args, "replace_all") == true

    cond do
      occurrences == 0 ->
        {:error, "Patch target not found."}

      occurrences > 1 and not replace_all? ->
        {:error, "Patch target has multiple occurrences. Use 'replace_all' to confirm."}

      true ->
        updated = String.replace(content, old_text, new_text, global: replace_all?)
        replacements = if replace_all?, do: occurrences, else: 1
        {:ok, updated, replacements}
    end
  end

  defp normalize_anchored_edits(args) do
    edits = Args.get(args, "edits")

    if is_list(edits) and edits != [] do
      edits
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {edit, index}, {:ok, acc} ->
        case normalize_anchored_edit(edit, index) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, list} -> {:ok, Enum.reverse(list)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "'anchored_edit' requires a non-empty 'edits' list."}
    end
  end

  defp normalize_anchored_edit(edit, index) when is_map(edit) do
    with {:ok, op} <- normalize_anchored_op(Args.get(edit, "op"), index),
         {:ok, anchor} <- fetch_anchored_ref(edit, "anchor", index),
         {:ok, content} <- FileSystem.fetch_required_string(edit, "content") do
      end_anchor =
        case Args.get(edit, "end_anchor") do
          nil -> nil
          value when is_binary(value) -> value
          _ -> :invalid
        end

      case {op, end_anchor} do
        {"replace", :invalid} ->
          {:error, "Edit #{index} has invalid 'end_anchor'."}

        {"replace", _} ->
          {:ok, %{op: op, anchor: anchor, end_anchor: end_anchor, content: content}}

        {_other, nil} ->
          {:ok, %{op: op, anchor: anchor, content: content}}

        {_other, _value} ->
          {:error, "Only 'replace' supports 'end_anchor'."}
      end
    end
  end

  defp normalize_anchored_edit(_edit, _index),
    do: {:error, "Each anchored edit must be an object."}

  defp normalize_anchored_op(op, _index) when op in ["replace", "insert_after", "insert_before"],
    do: {:ok, op}

  defp normalize_anchored_op(_op, index),
    do:
      {:error,
       "Edit #{index} has invalid 'op'. Expected replace, insert_after, or insert_before."}

  defp fetch_anchored_ref(args, key, index) do
    case Args.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Edit #{index} is missing '#{key}'."}
    end
  end

  defp apply_anchored_edits(content, edits) do
    {lines, trailing_newline?} = split_content_lines(content)

    with {:ok, validated_edits} <- validate_anchored_edits(lines, edits) do
      updated_lines =
        validated_edits
        |> Enum.sort_by(&anchored_sort_key/1, :desc)
        |> Enum.reduce(lines, &apply_anchored_edit/2)

      {:ok, join_content_lines(updated_lines, trailing_newline?), length(validated_edits)}
    end
  end

  defp validate_anchored_edits(lines, edits) do
    edits
    |> Enum.reduce_while({:ok, []}, fn edit, {:ok, acc} ->
      with {:ok, anchor} <- parse_line_ref(edit.anchor),
           :ok <- validate_line_anchor(lines, anchor),
           {:ok, normalized_edit} <- normalize_validated_edit(edit, lines, anchor) do
        {:cont, {:ok, [normalized_edit | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_validated_edit(%{op: "replace", end_anchor: nil} = edit, _lines, anchor) do
    {:ok, Map.put(edit, :anchor_data, anchor)}
  end

  defp normalize_validated_edit(%{op: "replace", end_anchor: end_anchor} = edit, lines, anchor) do
    with {:ok, parsed_end_anchor} <- parse_line_ref(end_anchor),
         :ok <- validate_line_anchor(lines, parsed_end_anchor),
         :ok <- validate_anchor_order(anchor, parsed_end_anchor) do
      {:ok, edit |> Map.put(:anchor_data, anchor) |> Map.put(:end_anchor_data, parsed_end_anchor)}
    end
  end

  defp normalize_validated_edit(edit, _lines, anchor) do
    {:ok, Map.put(edit, :anchor_data, anchor)}
  end

  defp validate_anchor_order(%{line: start_line}, %{line: end_line}) when end_line >= start_line,
    do: :ok

  defp validate_anchor_order(_start_anchor, _end_anchor),
    do: {:error, "'end_anchor' must be on or after 'anchor'."}

  defp anchored_sort_key(%{op: "replace", anchor_data: %{line: line}}), do: {line, 2}
  defp anchored_sort_key(%{op: "insert_after", anchor_data: %{line: line}}), do: {line, 1}
  defp anchored_sort_key(%{op: "insert_before", anchor_data: %{line: line}}), do: {line, 0}

  defp apply_anchored_edit(%{op: "replace", anchor_data: %{line: line}} = edit, lines) do
    replacement = split_edit_lines(edit.content)
    end_line = Map.get(edit, :end_anchor_data, %{line: line}).line
    prefix = Enum.take(lines, line - 1)
    suffix = Enum.drop(lines, end_line)
    Enum.concat([prefix, replacement, suffix])
  end

  defp apply_anchored_edit(
         %{op: "insert_after", anchor_data: %{line: line}, content: content},
         lines
       ) do
    insertion = split_edit_lines(content)
    {prefix, suffix} = Enum.split(lines, line)
    Enum.concat([prefix, insertion, suffix])
  end

  defp apply_anchored_edit(
         %{op: "insert_before", anchor_data: %{line: line}, content: content},
         lines
       ) do
    insertion = split_edit_lines(content)
    {prefix, suffix} = Enum.split(lines, line - 1)
    Enum.concat([prefix, insertion, suffix])
  end

  defp split_edit_lines(content) do
    content
    |> String.split("\n", trim: false)
    |> drop_trailing_empty_line()
  end

  defp join_content_lines([], _trailing_newline?), do: ""

  defp join_content_lines(lines, trailing_newline?) do
    rendered = Enum.join(lines, "\n")
    if trailing_newline?, do: rendered <> "\n", else: rendered
  end

  defp write_updated_content(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "Error writing file: #{inspect(reason)}"}
    end
  end

  defp parse_line_ref(ref) when is_binary(ref) do
    normalized = ref |> String.trim() |> String.replace_prefix("LINE#", "")

    case Regex.run(@line_ref_regex, normalized) do
      [_, line, hash] ->
        {:ok, %{line: String.to_integer(line), hash: hash}}

      _ ->
        {:error, "Invalid line reference format: #{inspect(ref)}. Expected format: {line}#ID."}
    end
  end

  defp validate_line_anchor(lines, %{line: line, hash: hash}) do
    cond do
      line < 1 or line > length(lines) ->
        {:error, "Line number #{line} out of bounds. File has #{length(lines)} lines."}

      compute_line_hash(line, Enum.at(lines, line - 1, "")) != hash ->
        {:error, format_anchor_mismatch(line, hash, lines)}

      true ->
        :ok
    end
  end

  defp format_anchor_mismatch(line, expected_hash, lines) do
    lower = max(line - 2, 1)
    upper = min(line + 2, length(lines))

    window =
      lower..upper
      |> Enum.map_join("\n", fn current_line ->
        content = Enum.at(lines, current_line - 1, "")
        anchor = "#{current_line}##{compute_line_hash(current_line, content)}|#{content}"
        if current_line == line, do: ">>> " <> anchor, else: "    " <> anchor
      end)

    "Line #{line} has changed since last read (expected #{line}##{expected_hash}). Use updated anchors below:\n\n" <>
      window
  end

  defp compute_line_hash(line_number, content) do
    stripped =
      content
      |> String.trim_trailing("\r")
      |> String.replace(~r/\s+/u, "")

    seed =
      if String.match?(stripped, ~r/[\p{L}\p{N}]/u) do
        stripped
      else
        "#{line_number}:#{stripped}"
      end

    hash_bin = :crypto.hash(:sha256, seed)
    <<n1::4, n2::4, n3::4, n4::4, n5::4, _::bitstring>> = hash_bin

    [n1, n2, n3, n4, n5]
    |> Enum.map(&elem(@hashline_dict, &1))
    |> Enum.join()
  end
end
