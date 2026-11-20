defmodule Pincer.Core.Executor.StreamAccumulator do
  @moduledoc """
  Consumes streamed LLM response chunks into a normalized assistant message map,
  emitting visible content tokens to a callback while filtering internal thinking
  and XML tool-call scaffolding.
  """

  alias Pincer.Core.TurnOutcomePolicy
  alias Pincer.Utils.Text

  @filter_tags [
    "<function",
    "<parameter",
    "<tool_call",
    "<think",
    "<thought",
    "<thinking",
    "<antthinking",
    "<relevant-memories",
    "<relevant_memories",
    "<final"
  ]

  @closing_tags [
    "</function>",
    "</tool_call>",
    "</think>",
    "</thought>",
    "</thinking>",
    "</antthinking>",
    "</final>",
    "</relevant-memories>",
    "</relevant_memories>"
  ]

  defstruct text: "", reasoning: "", tool_calls: %{}, buffer: "", filtering?: false

  @doc """
  Reduces `stream` chunks into an assistant message map, invoking `on_token` for
  user-visible text chunks.
  """
  @spec consume(Enumerable.t(), (String.t() -> term())) :: map()
  def consume(stream, on_token \\ fn _token -> :ok end) when is_function(on_token, 1) do
    acc = Enum.reduce(stream, %__MODULE__{}, &process_chunk(&1, &2, on_token))
    full_content = flush_buffer(acc, on_token)
    content = TurnOutcomePolicy.merge_reasoning_and_content(full_content, acc.reasoning)

    %{
      "role" => "assistant",
      "content" => if(content == "", do: nil, else: content),
      "tool_calls" => format_tool_calls(acc.tool_calls),
      "streamed_text" =>
        content
        |> Text.strip_reasoning()
        |> Text.strip_internal_scaffolding()
    }
  end

  defp process_chunk(%{"choices" => [%{"delta" => delta} | _]}, acc, on_token)
       when is_map(delta) do
    content = delta["content"] || delta[:content] || ""
    reasoning = delta["reasoning"] || delta["reasoning_content"] || delta[:reasoning] || ""
    tool_deltas = delta["tool_calls"] || delta[:tool_calls]

    acc
    |> append_content(content, on_token)
    |> append_reasoning(reasoning)
    |> merge_tool_deltas(tool_deltas)
  end

  defp process_chunk(_chunk, acc, _on_token), do: acc

  defp append_content(acc, content, on_token) when is_binary(content) and content != "" do
    process_text(acc.buffer <> content, %{acc | buffer: ""}, on_token)
  end

  defp append_content(acc, _content, _on_token), do: acc

  defp process_text("", acc, _on_token), do: acc

  defp process_text(text, %__MODULE__{filtering?: true} = acc, on_token) do
    case find_first_match(text, @closing_tags) do
      {tag, index} ->
        close_end = index + byte_size(tag)
        hidden = binary_part(text, 0, close_end)
        after_closer = binary_part(text, close_end, byte_size(text) - close_end)

        updated = %{acc | text: acc.text <> hidden, buffer: "", filtering?: false}
        process_text(after_closer, updated, on_token)

      nil ->
        %{acc | buffer: text, filtering?: true}
    end
  end

  defp process_text(text, %__MODULE__{filtering?: false} = acc, on_token) do
    case find_first_match(text, @filter_tags) do
      {tag, index} ->
        visible = binary_part(text, 0, index)
        rest = binary_part(text, index, byte_size(text) - index)
        if visible != "", do: on_token.(visible)
        _ = tag
        process_text(rest, %{acc | text: acc.text <> visible, filtering?: true}, on_token)

      nil ->
        case trailing_tag_prefix_index(text) do
          nil ->
            on_token.(text)
            %{acc | text: acc.text <> text, buffer: "", filtering?: false}

          split_idx ->
            visible = binary_part(text, 0, split_idx)
            pending = binary_part(text, split_idx, byte_size(text) - split_idx)
            if visible != "", do: on_token.(visible)
            %{acc | text: acc.text <> visible, buffer: pending, filtering?: false}
        end
    end
  end

  defp find_first_match(text, patterns) do
    patterns
    |> Enum.flat_map(fn pattern ->
      case :binary.match(text, pattern) do
        {index, _len} -> [{pattern, index}]
        :nomatch -> []
      end
    end)
    |> Enum.min_by(fn {_pattern, index} -> index end, fn -> nil end)
  end

  defp trailing_tag_prefix_index(text) do
    case :binary.matches(text, "<") do
      [] ->
        nil

      matches ->
        {last_lt, _len} = List.last(matches)
        tail = binary_part(text, last_lt, byte_size(text) - last_lt)

        if Enum.any?(@filter_tags, &String.starts_with?(&1, tail)) do
          last_lt
        else
          nil
        end
    end
  end

  defp flush_buffer(%__MODULE__{text: text, buffer: ""}, _on_token), do: text

  defp flush_buffer(%__MODULE__{text: text, buffer: buffer, filtering?: false}, on_token) do
    on_token.(buffer)
    text <> buffer
  end

  defp flush_buffer(%__MODULE__{text: text, buffer: buffer, filtering?: true}, _on_token) do
    visible_tail =
      buffer
      |> Text.strip_reasoning()
      |> Text.strip_internal_scaffolding()

    if String.trim(visible_tail) == "", do: text, else: text <> visible_tail
  end

  defp append_reasoning(acc, reasoning) when is_binary(reasoning) and reasoning != "" do
    %{acc | reasoning: acc.reasoning <> reasoning}
  end

  defp append_reasoning(acc, _reasoning), do: acc

  defp merge_tool_deltas(acc, deltas) when is_list(deltas) do
    merged =
      Enum.reduce(deltas, acc.tool_calls, fn delta, inner_acc ->
        index = read_field(delta, "index", :index)

        existing =
          Map.get(inner_acc, index, %{
            "index" => index,
            "id" => nil,
            "type" => "function",
            "function" => %{"name" => "", "arguments" => ""}
          })

        fn_delta = read_field(delta, "function", :function) || %{}
        type_delta = delta |> read_field("type", :type) |> normalize_binary()
        name_delta = fn_delta |> read_field("name", :name) |> normalize_binary() || ""

        args_delta =
          fn_delta
          |> read_field("arguments", :arguments)
          |> normalize_arguments_fragment()

        updated =
          existing
          |> Map.put("id", read_field(delta, "id", :id) || existing["id"])
          |> Map.put("type", type_delta || existing["type"] || "function")
          |> put_in(["function", "name"], (existing["function"]["name"] || "") <> name_delta)
          |> put_in(
            ["function", "arguments"],
            (existing["function"]["arguments"] || "") <> args_delta
          )

        Map.put(inner_acc, index, updated)
      end)

    %{acc | tool_calls: merged}
  end

  defp merge_tool_deltas(acc, _deltas), do: acc

  defp format_tool_calls(tool_calls) when map_size(tool_calls) == 0, do: nil

  defp format_tool_calls(tool_calls) do
    tool_calls
    |> Map.values()
    |> Enum.sort_by(& &1["index"])
    |> Enum.map(&Map.delete(&1, "index"))
  end

  defp read_field(map, string_key, atom_key) when is_map(map) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end

  defp normalize_arguments_fragment(nil), do: ""
  defp normalize_arguments_fragment(bin) when is_binary(bin), do: bin
  defp normalize_arguments_fragment(map) when is_map(map), do: Jason.encode!(map)
  defp normalize_arguments_fragment(_), do: ""

  defp normalize_binary(nil), do: nil
  defp normalize_binary(bin) when is_binary(bin), do: bin
  defp normalize_binary(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize_binary(other), do: inspect(other)
end
